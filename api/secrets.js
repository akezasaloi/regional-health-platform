'use strict';

/**
 * Load the Aiven envelope from Secrets Manager (C3).
 * No MYSQL_* fallback when DB_SECRET_ARN is set — env fallback is not C3.
 */

const http = require('http');
const https = require('https');

let loadedArn = null;

function secretSourceArn() {
  return loadedArn;
}

function postJson(endpoint, target, body) {
  const u = new URL(endpoint);
  const payload = JSON.stringify(body);
  const lib = u.protocol === 'https:' ? https : http;
  const options = {
    hostname: u.hostname,
    port: u.port || (u.protocol === 'https:' ? 443 : 80),
    path: u.pathname && u.pathname !== '/' ? u.pathname : '/',
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-amz-json-1.1',
      'X-Amz-Target': target,
      'Content-Length': Buffer.byteLength(payload),
      Host: u.host,
      Authorization: 'AWS4-HMAC-SHA256 Credential=test/20100101/us-east-1/secretsmanager/aws4_request, SignedHeaders=host, Signature=0',
    },
  };
  return new Promise((resolve, reject) => {
    const req = lib.request(options, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error(`GetSecretValue ${res.statusCode}: ${text}`));
          return;
        }
        try {
          resolve(JSON.parse(text));
        } catch (err) {
          reject(err);
        }
      });
    });
    req.on('error', reject);
    req.setTimeout(10_000, () => {
      req.destroy(new Error('GetSecretValue timed out'));
    });
    req.end(payload);
  });
}

async function loadDbSecrets() {
  const arn = process.env.DB_SECRET_ARN;
  if (!arn) {
    return null;
  }
  const endpoint = process.env.AWS_ENDPOINT_URL || 'http://127.0.0.1:4566';
  const targets = ['secretsmanager.GetSecretValue', 'SecretsManager.GetSecretValue'];
  let lastErr;
  let data;
  for (const target of targets) {
    try {
      data = await postJson(endpoint, target, { SecretId: arn });
      lastErr = null;
      break;
    } catch (err) {
      lastErr = err;
    }
  }
  if (lastErr) {
    throw lastErr;
  }
  if (!data || !data.SecretString) {
    throw new Error('GetSecretValue returned no SecretString');
  }
  const secret = JSON.parse(data.SecretString);
  loadedArn = data.ARN || arn;
  return secret;
}

module.exports = { loadDbSecrets, secretSourceArn };
