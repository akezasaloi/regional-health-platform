#!/usr/bin/env bash
# =============================================================================
# scripts/verify.sh — C8: one command, fail loud
# -----------------------------------------------------------------------------
# Exits non-zero if any of:
#   1. terraform plan is not empty after apply
#   2. GET /healthz  → not 200
#   3. GET /readyz   → not 200
#   4. app did not resolve DB creds from Secrets Manager
#   5. gitleaks on the repo reports findings
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${TF_DIR:-${ROOT}/terraform/envs/${USER}}"
EVIDENCE_IAC="${ROOT}/evidence/01-iac"
EVIDENCE_SEC="${ROOT}/evidence/03-secrets"
FAILED=0

fail() { echo "FAIL: $*" >&2; FAILED=1; }
need() {
  command -v "$1" >/dev/null 2>&1 || { echo "FAIL: $1 not on PATH" >&2; exit 1; }
}

need curl
need jq
need gitleaks

# tflocal injects LocalStack endpoints. Plain `terraform plan` after a
# tflocal apply talks to real AWS and fails check 1 in CI.
if command -v tflocal >/dev/null 2>&1; then
  TF=(tflocal)
elif command -v terraform >/dev/null 2>&1; then
  TF=(terraform)
else
  echo "FAIL: terraform/tflocal not on PATH" >&2
  exit 1
fi

if [[ ! -d "${TF_DIR}" ]]; then
  echo "FAIL: no Terraform root at ${TF_DIR}" >&2
  exit 1
fi

mkdir -p "${EVIDENCE_IAC}" "${EVIDENCE_SEC}"

echo "== 1/5 terraform plan is empty after apply =="
# Match `make up`: tflocal -chdir=$TF_DIR plan (not pushd).
PLAN_RC=0
"${TF[@]}" -chdir="${TF_DIR}" plan -detailed-exitcode -no-color \
  > "${EVIDENCE_IAC}/plan-after-apply.txt" 2>&1 || PLAN_RC=$?
echo "    plan rc=${PLAN_RC} (0 empty, 2 changes, other error)"
case "${PLAN_RC}" in
  0) echo "OK: plan empty" ;;
  2)
    fail "plan is not empty — see ${EVIDENCE_IAC}/plan-after-apply.txt"
    sed -n '1,80p' "${EVIDENCE_IAC}/plan-after-apply.txt" >&2 || true
    ;;
  *)
    fail "terraform plan errored (rc=${PLAN_RC}) — see ${EVIDENCE_IAC}/plan-after-apply.txt"
    sed -n '1,80p' "${EVIDENCE_IAC}/plan-after-apply.txt" >&2 || true
    ;;
esac

echo "== 2/5 GET /healthz → 200 =="
APP_URL="${APP_URL:-$("${TF[@]}" -chdir="${TF_DIR}" output -raw app_url 2>/dev/null || true)}"
APP_URL="${APP_URL:-http://127.0.0.1:3000}"
echo "    target ${APP_URL}"

HZ_CODE="$(curl -s -o /tmp/healthz.body -w '%{http_code}' "${APP_URL}/healthz" || true)"
if [[ "${HZ_CODE}" == "200" ]]; then
  echo "OK: /healthz 200"
else
  fail "/healthz returned ${HZ_CODE:-curl-failed} (body: $(cat /tmp/healthz.body 2>/dev/null || true))"
fi

echo "== 3/5 GET /readyz → 200 =="
RZ_CODE="$(curl -s -o /tmp/readyz.body -w '%{http_code}' "${APP_URL}/readyz" || true)"
if [[ "${RZ_CODE}" == "200" ]]; then
  echo "OK: /readyz 200"
else
  fail "/readyz returned ${RZ_CODE:-curl-failed} (body: $(cat /tmp/readyz.body 2>/dev/null || true))"
fi

echo "== 4/5 DB creds resolved from Secrets Manager =="
SRC="$(curl -fsS "${APP_URL}/debug/secret-source" || true)"
if echo "${SRC}" | jq -e '.arn | type == "string" and startswith("arn:aws:secretsmanager:")' >/dev/null 2>&1; then
  echo "OK: secret-source ${SRC}"
else
  fail "secret-source is not a Secrets Manager ARN (got: ${SRC:-<empty>}). env fallback is not C3."
fi

echo "== 5/5 gitleaks on repo → zero findings =="
set +e
gitleaks detect --source "${ROOT}" --no-banner \
  --report-path "${EVIDENCE_SEC}/gitleaks.json" \
  --report-format json
GL_RC=$?
set -e
if [[ "${GL_RC}" -eq 0 ]]; then
  echo "OK: gitleaks clean"
else
  fail "gitleaks reported findings — see ${EVIDENCE_SEC}/gitleaks.json"
fi

if [[ "${FAILED}" -ne 0 ]]; then
  echo "verify: FAILED plan_rc=${PLAN_RC} healthz=${HZ_CODE:-?} readyz=${RZ_CODE:-?} secret=${SRC:-<empty>} gitleaks=${GL_RC:-?}" >&2
  echo "::error::verify failed plan_rc=${PLAN_RC} healthz=${HZ_CODE:-?} readyz=${RZ_CODE:-?} secret=${SRC:-<empty>} gitleaks=${GL_RC:-?}"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo '## make verify'
      echo "- plan_rc: ${PLAN_RC}"
      echo "- healthz: ${HZ_CODE:-?}"
      echo "- readyz: ${RZ_CODE:-?}"
      echo "- secret-source: \`${SRC:-<empty>}\`"
      echo "- gitleaks: ${GL_RC:-?}"
      echo
      echo '### plan-after-apply (head)'
      echo '```'
      sed -n '1,80p' "${EVIDENCE_IAC}/plan-after-apply.txt" 2>/dev/null || true
      echo '```'
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
  exit 1
fi
echo "verify: all 5 checks passed"
