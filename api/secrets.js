'use strict';

// secrets.js — resolve DB credentials from Secrets Manager at boot (C3).
// AWS_ENDPOINT_URL points the SDK at LocalStack; unset on real AWS. No
// environment branch: the same binary runs in both. Only ARN + VersionId are
// ever logged or exposed.

const {
  SecretsManagerClient,
  GetSecretValueCommand,
} = require('@aws-sdk/client-secrets-manager');

// { arn, versionId } — safe to expose. Never holds a secret value.
let source = { arn: null, versionId: null };
let cached = null;

/**
 * Returns { engine, username, password, host, port, dbname }.
 * Without DB_SECRET_ARN, falls back to MYSQL_* env for local compose runs —
 * reported as { arn: 'env' }, which /debug/secret-source treats as not-ready.
 */
async function loadDbCredentials() {
  const arn = process.env.DB_SECRET_ARN;

  if (!arn) {
    source = { arn: 'env', versionId: 'n/a' };
    cached = {
      engine: 'mysql',
      username: process.env.MYSQL_USER || 'root',
      password: process.env.MYSQL_PASSWORD || 'labpassword',
      host: process.env.MYSQL_HOST || 'mysql-db',
      port: Number(process.env.MYSQL_PORT || 3306),
      dbname: process.env.MYSQL_DATABASE || 'capacity_lab',
    };
    // eslint-disable-next-line no-console
    console.log('boot: DB_SECRET_ARN unset — using MYSQL_* env (not C3)');
    return cached;
  }

  const client = new SecretsManagerClient({
    endpoint: process.env.AWS_ENDPOINT_URL || undefined,
    region: process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || 'us-east-1',
  });

  const res = await client.send(new GetSecretValueCommand({ SecretId: arn }));
  if (!res || !res.SecretString) {
    throw new Error(`GetSecretValue returned no SecretString for ${arn}`);
  }

  cached = JSON.parse(res.SecretString);
  source = { arn: res.ARN || arn, versionId: res.VersionId || null };

  // ARN + version only — boot.log is committed as C3 evidence.
  // eslint-disable-next-line no-console
  console.log(`boot: db credentials from ${source.arn} version ${source.versionId}`);

  return cached;
}

/** { arn, versionId } for /debug/secret-source. Never any secret value. */
function getSecretSource() {
  return { ...source };
}

/** True once credentials resolved from Secrets Manager (not the env fallback). */
function secretResolved() {
  return cached !== null && source.arn !== null && source.arn !== 'env';
}

module.exports = { loadDbCredentials, getSecretSource, secretResolved };
