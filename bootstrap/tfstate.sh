#!/usr/bin/env bash
# =============================================================================
# bootstrap/tfstate.sh
# -----------------------------------------------------------------------------
# Create the LocalStack S3 bucket + DynamoDB lock table used as Terraform
# remote state. The AWS password for RDS lands in state in cleartext, so the
# bucket is versioned, encrypted, and never public. Recreates are idempotent.
#
# Requires: LOCALSTACK_AUTH_TOKEN, awslocal (pip install awscli-local).
# =============================================================================
set -euo pipefail

: "${LOCALSTACK_AUTH_TOKEN:?export LOCALSTACK_AUTH_TOKEN (Hobby token from app.localstack.cloud)}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

BUCKET="${TF_STATE_BUCKET:-tfstate-regional-health}"
TABLE="${TF_STATE_LOCK_TABLE:-tfstate-lock}"
ENDPOINT="${AWS_ENDPOINT_URL:-http://localhost:4566}"

if ! command -v awslocal >/dev/null 2>&1; then
  echo "FAIL: awslocal not on PATH. Install with: pipx install awscli-local" >&2
  exit 1
fi

echo ">> waiting for LocalStack at ${ENDPOINT} ..."
for _ in $(seq 1 60); do
  if curl -fsS "${ENDPOINT}/_localstack/health" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
curl -fsS "${ENDPOINT}/_localstack/health" >/dev/null \
  || { echo "FAIL: LocalStack is not up at ${ENDPOINT}. Run: localstack start -d" >&2; exit 1; }

echo ">> ensuring S3 bucket s3://${BUCKET} (versioned + SSE-S3, not public)"
awslocal s3api create-bucket --bucket "${BUCKET}" >/dev/null 2>&1 || true
awslocal s3api put-bucket-versioning \
  --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled
awslocal s3api put-bucket-encryption \
  --bucket "${BUCKET}" \
  --server-side-encryption-configuration '{
    "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]
  }'
awslocal s3api put-public-access-block \
  --bucket "${BUCKET}" \
  --public-access-block-configuration '{
    "BlockPublicAcls":true,
    "IgnorePublicAcls":true,
    "BlockPublicPolicy":true,
    "RestrictPublicBuckets":true
  }'

echo ">> ensuring DynamoDB lock table ${TABLE}"
awslocal dynamodb create-table \
  --table-name "${TABLE}" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST >/dev/null 2>&1 || true

echo ">> remote state ready: s3://${BUCKET}  lock=${TABLE}"
echo "   point terraform at terraform/backend.example.hcl (copy into your env)."
