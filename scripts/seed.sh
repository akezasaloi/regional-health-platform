#!/usr/bin/env bash
# =============================================================================
# scripts/seed.sh — C2: schema + 10k patients onto Aiven MySQL via mysqldump
# -----------------------------------------------------------------------------
# Migration path (assignment still requires mysqldump | mysql — no Cloud Pods):
#   1. spin a throwaway mysql:8.0
#   2. run data-seed/seed.sh (ROW_COUNT=10000) + data-seed/01-fixes.sql
#   3. mysqldump
#   4. restore into Aiven over TLS
#
# Credentials come from Secrets Manager (never from git). Terraform wrote the
# Aiven envelope there at apply. Optional AIVEN_CA_PATH for VERIFY_CA.
# Aiven free-plan services sleep when idle — we retry until the host wakes.
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
if ! command -v mysql >/dev/null 2>&1; then
  echo "FAIL: mysql client not on PATH" >&2
  exit 1
fi
if [[ ! -d "${TF_DIR}" ]]; then
  echo "FAIL: no Terraform root at ${TF_DIR}" >&2
  echo "      copy terraform/envs/_template → terraform/envs/<you>," >&2
  echo "      or pass TF_DIR=/path/to/your/root" >&2
  exit 1
fi

mkdir -p "${EVIDENCE}"
exec > >(tee -a "${EVIDENCE}/seed.log") 2>&1

echo ">> reading Terraform outputs from ${TF_DIR}"
pushd "${TF_DIR}" >/dev/null
SECRET_ARN="$(terraform output -raw secret_arn)"
popd >/dev/null

echo ">> fetching DB credentials from Secrets Manager ${SECRET_ARN}"
CREDS_JSON="$(awslocal secretsmanager get-secret-value \
  --secret-id "${SECRET_ARN}" --query SecretString --output text)"
DB_USER="$(echo "${CREDS_JSON}" | jq -r '.username // empty')"
DB_PASS="$(echo "${CREDS_JSON}" | jq -r '.password // empty')"
ENDPOINT="$(echo "${CREDS_JSON}" | jq -r '.host // empty')"
PORT="$(echo "${CREDS_JSON}" | jq -r '.port // empty')"
DB_NAME="$(echo "${CREDS_JSON}" | jq -r '.dbname // empty')"
unset CREDS_JSON

# AIVEN_HOST is often pasted as the Service URI or "host:port". DNS then looks
# up that whole string and mysql reports ERROR 2005 / "No address associated
# with hostname" for 12 minutes. Parse it; never print the secret.
parsed="$(
  RAW_HOST="${ENDPOINT}" RAW_PORT="${PORT}" python3 - <<'PY'
import os, socket, sys
from urllib.parse import urlparse

raw_host = os.environ.get("RAW_HOST", "")
raw_port = os.environ.get("RAW_PORT", "")
host = raw_host.strip().strip('"').strip("'")
port = str(raw_port).strip().strip('"').strip("'")

if "://" in host:
    u = urlparse(host)
    host = u.hostname or ""
    if u.port:
        port = str(u.port)

if host.count(":") == 1 and not host.startswith("["):
    h, p = host.rsplit(":", 1)
    if p.isdigit():
        host, port = h, p

host = host.strip().split("/")[0]
port = port.strip()

def shape():
    return (
        f"host_len={len(host)} dots={host.count('.')} space={int(' ' in host)} "
        f"slash={int('/' in raw_host)} scheme={int('://' in raw_host)} "
        f"looks_aiven={int(host.endswith(('.aivencloud.com', '.aiven.io')))} "
        f"port={port!r} port_digits={port.isdigit()}"
    )

if not host or host in {"null", "None", "undefined"}:
    print(f"FAIL: Secrets Manager host is empty after parse ({shape()})", file=sys.stderr)
    sys.exit(2)
if not port.isdigit():
    print(f"FAIL: Secrets Manager port is not a number ({shape()})", file=sys.stderr)
    sys.exit(2)

try:
    socket.getaddrinfo(host, int(port), type=socket.SOCK_STREAM)
except socket.gaierror as err:
    print(f"FAIL: AIVEN_HOST does not resolve in DNS ({err}; {shape()})", file=sys.stderr)
    print(
        "Set GitHub secret AIVEN_HOST to the Aiven *Host* field only "
        "(e.g. mysql-….a.aivencloud.com), not the Service URI, not host:port, "
        "no quotes, no https://. AIVEN_PORT is digits only (not 3306 on the free plan).",
        file=sys.stderr,
    )
    sys.exit(1)

print(host)
print(port)
PY
)" || exit 1
ENDPOINT="$(echo "${parsed}" | sed -n '1p')"
PORT="$(echo "${parsed}" | sed -n '2p')"
echo ">> Aiven DNS resolved (port digits=${#PORT})"

# CI installs Ubuntu's `mysql-client`, which is MariaDB. That binary does not
# implement MySQL's `--ssl-mode` (unknown variable → instant fail). We used to
# throw that away (`>/dev/null 2>&1`) and report "Aiven never answered", which
# was wrong: Terraform had already stored the envelope, so the host/port were
# set. Keep TLS on; pick flags the installed client actually understands.
echo ">> mysql client: $(mysql --version)"
ssl_args=()
if mysql --help 2>/dev/null | grep -q -- '--ssl-mode'; then
  if [[ -n "${AIVEN_CA_PATH:-}" ]]; then
    if [[ ! -f "${AIVEN_CA_PATH}" ]]; then
      echo "FAIL: AIVEN_CA_PATH=${AIVEN_CA_PATH} is not a file" >&2
      exit 1
    fi
    ssl_args=(--ssl-mode=VERIFY_CA --ssl-ca="${AIVEN_CA_PATH}")
    echo ">> TLS: MySQL --ssl-mode=VERIFY_CA with ${AIVEN_CA_PATH}"
  else
    ssl_args=(--ssl-mode=REQUIRED)
    echo ">> TLS: MySQL --ssl-mode=REQUIRED (set AIVEN_CA_PATH for VERIFY_CA)"
  fi
else
  if [[ -n "${AIVEN_CA_PATH:-}" ]]; then
    if [[ ! -f "${AIVEN_CA_PATH}" ]]; then
      echo "FAIL: AIVEN_CA_PATH=${AIVEN_CA_PATH} is not a file" >&2
      exit 1
    fi
    ssl_args=(--ssl --ssl-verify-server-cert --ssl-ca="${AIVEN_CA_PATH}")
    echo ">> TLS: MariaDB --ssl --ssl-verify-server-cert with ${AIVEN_CA_PATH}"
  else
    ssl_args=(--ssl)
    echo ">> TLS: MariaDB --ssl (required encryption; set AIVEN_CA_PATH for VERIFY_CA)"
  fi
fi

redact() {
  local s
  s="$(cat)"
  s="${s//"${DB_PASS}"/***}"
  s="${s//"${ENDPOINT}"/***}"
  printf '%s' "${s}"
}

mysql_aiven() {
  mysql -h "${ENDPOINT}" -P "${PORT}" -u "${DB_USER}" -p"${DB_PASS}" \
    --connect-timeout=20 "${ssl_args[@]}" "$@"
}

echo ">> probing TCP ${ENDPOINT}:${PORT}"
if timeout 15 bash -c "echo >/dev/tcp/${ENDPOINT}/${PORT}" 2>/tmp/aiven.tcp.err; then
  echo ">> TCP is open (service is reachable; a mysql failure is TLS/auth, not sleep)"
else
  echo ">> TCP not open yet (free plan may be powered off). last: $(redact </tmp/aiven.tcp.err)"
fi

echo ">> waiting for Aiven ${ENDPOINT}:${PORT} as ${DB_USER} (TLS, free plan sleeps when idle) ..."
awake=0
last_err=""
# Aiven power-off → running can take several minutes; 12 min is still cheaper
# than a false "never answered" caused by a client flag the binary rejects.
for i in $(seq 1 72); do
  if last_err="$(mysql_aiven -e "SELECT 1" 2>&1)"; then
    awake=1
    break
  fi
  if [[ $((i % 6)) -eq 1 ]]; then
    echo ">> try ${i}/72: $(echo "${last_err}" | redact | tr '\n' ' ')"
  fi
  sleep 10
done
if [[ "${awake}" -ne 1 ]]; then
  echo "FAIL: Aiven never accepted SELECT 1 on ${ENDPOINT}:${PORT} as ${DB_USER}." >&2
  echo "      last mysql: $(echo "${last_err}" | redact)" >&2
  echo "      If TCP stayed closed: open the service in the Aiven console (powered off ≠ idle)." >&2
  echo "      If TCP was open: check AIVEN_PASSWORD / AIVEN_PORT in Actions secrets." >&2
  exit 1
fi
echo ">> Aiven is up"
echo ">> ensuring database ${DB_NAME} exists"
mysql_aiven -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"

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

echo ">> restoring dump into Aiven ${ENDPOINT}:${PORT}/${DB_NAME} as ${DB_USER} (TLS)"
mysql_aiven "${DB_NAME}" < /tmp/capacity_lab.dump.sql

echo ">> row counts (C2 evidence)"
{
  echo "# captured $(date -u +%Y-%m-%dT%H:%M:%SZ)  ROW_COUNT=${ROW_COUNT}"
  mysql_aiven "${DB_NAME}" -N -e "
      SELECT CONCAT('patients=', COUNT(*)) FROM patients;
      SELECT CONCAT('hospitals=', COUNT(*)) FROM hospitals;
    "
} | tee "${EVIDENCE}/row-counts.txt"

PATIENTS="$(awk -F= '/^patients=/{print $2}' "${EVIDENCE}/row-counts.txt")"
if [[ -z "${PATIENTS}" || "${PATIENTS}" -lt "${ROW_COUNT}" ]]; then
  echo "FAIL: expected ${ROW_COUNT} patients, got ${PATIENTS:-<empty>}" >&2
  exit 1
fi

echo ">> seed complete — ${PATIENTS} patients in Aiven ${DB_NAME}"
unset DB_PASS
