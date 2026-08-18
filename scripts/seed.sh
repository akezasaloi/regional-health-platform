#!/usr/bin/env bash
# =============================================================================
# scripts/seed.sh — C2: schema + 10k patients onto RDS via mysqldump restore
# -----------------------------------------------------------------------------
# Cloud Pods / RDS snapshots are not on Hobby, so the migration path is:
#   1. spin a throwaway mysql:8.0
#   2. run data-seed/seed.sh (ROW_COUNT=10000) + data-seed/01-fixes.sql
#   3. mysqldump
#   4. restore into the RDS instance Terraform just created
#
# Credentials come from Secrets Manager (never from git). Terraform outputs
# supply the secret ARN + endpoint.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${TF_DIR:-${ROOT}/terraform/envs/${USER}}"
ROW_COUNT="${ROW_COUNT:-10000}"
EVIDENCE="${ROOT}/evidence/02-data"
SRC_NAME="seed-src-$$"

: "${LOCALSTACK_AUTH_TOKEN:?export LOCALSTACK_AUTH_TOKEN}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

if ! command -v awslocal >/dev/null 2>&1; then
  echo "FAIL: awslocal not on PATH" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq not on PATH" >&2
  exit 1
fi
if [[ ! -d "${TF_DIR}" ]]; then
  echo "FAIL: no Terraform root at ${TF_DIR}" >&2
  echo "      copy terraform/envs/_template → terraform/envs/<you> after PR-A/PR-B merge," >&2
  echo "      or pass TF_DIR=/path/to/your/root" >&2
  exit 1
fi

mkdir -p "${EVIDENCE}"
exec > >(tee -a "${EVIDENCE}/seed.log") 2>&1

echo ">> reading Terraform outputs from ${TF_DIR}"
pushd "${TF_DIR}" >/dev/null
ENDPOINT="$(terraform output -raw db_endpoint)"
PORT="$(terraform output -raw db_port)"
SECRET_ARN="$(terraform output -raw secret_arn)"
popd >/dev/null

# Gotcha #1: LocalStack RDS often reports host=localhost. From the Linux
# host / Codespace that is the emulator; from inside an EC2 container it is
# the instance itself. Prefer the LocalStack DNS name.
if [[ "${ENDPOINT}" == "localhost" || "${ENDPOINT}" == "127.0.0.1" ]]; then
  ENDPOINT="${RDS_HOST_OVERRIDE:-localhost.localstack.cloud}"
  echo ">> remapped RDS host to ${ENDPOINT} (LocalStack localhost quirk — see FIDELITY.md)"
fi

echo ">> fetching DB credentials from Secrets Manager ${SECRET_ARN}"
CREDS_JSON="$(awslocal secretsmanager get-secret-value \
  --secret-id "${SECRET_ARN}" --query SecretString --output text)"
DB_USER="$(echo "${CREDS_JSON}" | jq -r .username)"
DB_PASS="$(echo "${CREDS_JSON}" | jq -r .password)"
DB_NAME="$(echo "${CREDS_JSON}" | jq -r .dbname)"
unset CREDS_JSON

cleanup() {
  docker rm -f "${SRC_NAME}" >/dev/null 2>&1 || true
  rm -f /tmp/capacity_lab.dump.sql
}
trap cleanup EXIT

echo ">> starting throwaway mysql:8.0 to generate a mysqldump (ROW_COUNT=${ROW_COUNT})"
docker run --rm -d --name "${SRC_NAME}" \
  -e MYSQL_ROOT_PASSWORD=labpassword \
  -e MYSQL_DATABASE=capacity_lab \
  mysql:8.0 \
  --default-authentication-plugin=mysql_native_password >/dev/null

echo ">> waiting for throwaway MySQL ..."
for _ in $(seq 1 60); do
  if docker exec "${SRC_NAME}" mysqladmin ping -plabpassword --silent >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker exec "${SRC_NAME}" mysqladmin ping -plabpassword --silent >/dev/null \
  || { echo "FAIL: throwaway MySQL never became ready"; exit 1; }

echo ">> loading schema + ${ROW_COUNT} patients into throwaway MySQL"
docker exec -e MYSQL_HOST=127.0.0.1 \
            -e MYSQL_PORT=3306 \
            -e MYSQL_USER=root \
            -e MYSQL_PASSWORD=labpassword \
            -e MYSQL_DATABASE=capacity_lab \
            -e ROW_COUNT="${ROW_COUNT}" \
            -i "${SRC_NAME}" bash < "${ROOT}/data-seed/seed.sh"
docker exec -i "${SRC_NAME}" mysql -uroot -plabpassword capacity_lab \
  < "${ROOT}/data-seed/01-fixes.sql"

echo ">> mysqldump throwaway → /tmp/capacity_lab.dump.sql"
docker exec "${SRC_NAME}" mysqldump -uroot -plabpassword \
  --single-transaction --routines --triggers capacity_lab \
  > /tmp/capacity_lab.dump.sql

echo ">> restoring dump into RDS ${ENDPOINT}:${PORT}/${DB_NAME} as ${DB_USER}"
mysql -h "${ENDPOINT}" -P "${PORT}" -u "${DB_USER}" -p"${DB_PASS}" \
  --connect-timeout=20 "${DB_NAME}" < /tmp/capacity_lab.dump.sql

echo ">> row counts (C2 evidence)"
{
  echo "# captured $(date -u +%Y-%m-%dT%H:%M:%SZ)  ROW_COUNT=${ROW_COUNT}"
  mysql -h "${ENDPOINT}" -P "${PORT}" -u "${DB_USER}" -p"${DB_PASS}" \
    -N -e "
      SELECT CONCAT('patients=', COUNT(*)) FROM ${DB_NAME}.patients;
      SELECT CONCAT('hospitals=', COUNT(*)) FROM ${DB_NAME}.hospitals;
    "
} | tee "${EVIDENCE}/row-counts.txt"

PATIENTS="$(awk -F= '/^patients=/{print $2}' "${EVIDENCE}/row-counts.txt")"
if [[ "${PATIENTS}" -lt "${ROW_COUNT}" ]]; then
  echo "FAIL: expected ${ROW_COUNT} patients, got ${PATIENTS}" >&2
  exit 1
fi

echo ">> seed complete — ${PATIENTS} patients in RDS"
unset DB_PASS
