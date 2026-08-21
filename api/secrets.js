'use strict';

// =============================================================================
// secrets.js — resolve DB credentials from AWS Secrets Manager at boot (C3).
//
// The client is configured with `endpoint: process.env.AWS_ENDPOINT_URL`. On
// LocalStack that points at :4566; on real AWS the variable is unset, the SDK
// resolves the public endpoint, and the credential chain supplies real creds.
// There is deliberately no environment-sniffing branch anywhere in this module —
// the same binary runs in both places, and the only difference is that variable.
//
// Only the ARN and VersionId are ever logged or exposed. The password is held
// in memory for the lifetime of the process and never leaves this module.
// =============================================================================

const {
  SecretsManagerClient,
  GetSecretValueCommand,
} = require('@aws-sdk/client-secrets-manager');

// { arn, versionId } — safe to expose. Never holds a secret value.
let source = { arn: null, versionId: null };
let cached = null;

/**
 * Resolve DB credentials. Returns the parsed envelope
 * { engine, username, password, host, port, dbname }.
 *
 * With DB_SECRET_ARN set, reads Secrets Manager. Without it, falls back to
 * MYSQL_* env vars so a plain `docker compose up` still works locally — that
 * path reports source { arn: 'env', versionId: 'n/a' }, which C8's
 * /debug/secret-source check treats as a failure, because env is not C3.
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
    // Unset on real AWS; the SDK then resolves the public endpoint itself.
    endpoint: process.env.AWS_ENDPOINT_URL || undefined,
    region: process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || 'us-east-1',
  });

  const res = await client.send(new GetSecretValueCommand({ SecretId: arn }));
  if (!res || !res.SecretString) {
    throw new Error(`GetSecretValue returned no SecretString for ${arn}`);
  }

  cached = JSON.parse(res.SecretString);
  source = { arn: res.ARN || arn, versionId: res.VersionId || null };

  // ARN + version only. Logging the envelope here would put the password in
  // boot.log, which is committed as C3 evidence.
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
