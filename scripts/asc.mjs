#!/usr/bin/env node
// Minimal App Store Connect API client for this app's release setup.
//
//   node scripts/asc.mjs GET /v1/apps?filter[bundleId]=com.saphid.duocord
//   node scripts/asc.mjs POST /v1/bundleIds '{"data": ...}'
//
// Credentials come from ASC_CONFIG (default ~/.appstoreconnect/frame-control.json:
// key_id, issuer_id, key_path). The token is signed in memory and never printed.
import { createPrivateKey, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';

const configPath = process.env.ASC_CONFIG || `${homedir()}/.appstoreconnect/frame-control.json`;
const config = JSON.parse(readFileSync(configPath, 'utf8'));

function token() {
  const b64 = (v) => Buffer.from(typeof v === 'string' ? v : JSON.stringify(v)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const header = b64({ alg: 'ES256', kid: config.key_id, typ: 'JWT' });
  const payload = b64({ iss: config.issuer_id, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' });
  const key = createPrivateKey(readFileSync(config.key_path));
  const signature = sign('sha256', Buffer.from(`${header}.${payload}`), { key, dsaEncoding: 'ieee-p1363' });
  return `${header}.${payload}.${signature.toString('base64url')}`;
}

const [method, path, body] = process.argv.slice(2);
if (!method || !path) {
  console.error('usage: asc.mjs METHOD /v1/path [json-body]');
  process.exit(64);
}
const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
  method,
  headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json' },
  body: body || undefined,
});
const text = await response.text();
process.stdout.write(`${response.status}\n${text}\n`);
process.exit(response.ok ? 0 : 1);
