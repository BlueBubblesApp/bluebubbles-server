#!/usr/bin/env node
//
// Generates the Ed25519 keypair the whole subscription rests on.
//
// Run this ONCE. The public half is compiled into every copy of the server; the private half
// exists only as a Cloudflare secret and must never be committed, pasted into a chat, or
// stored anywhere it can be read back. There is no recovery if it leaks: every token ever
// issued becomes forgeable, and the only fix is a new keypair and a server release, which
// strands every license until people update.
//
// Zero dependencies: Node built-ins only.
//
//   node keygen.mjs
//
// Then:
//   1. Put PUBLIC into `LicensePublicKey.base64` in Sources/BBLicense/TokenVerifier.swift.
//      That constant being empty is what currently keeps the gate switched off, so this is
//      the step that turns enforcement on.
//   2. `npx wrangler secret put SIGNING_KEY` and paste PRIVATE when prompted.

import crypto from 'node:crypto';

const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');

// Raw 32 bytes, base64. Both sides agree on this shape: swift-crypto's
// `Curve25519.Signing.PublicKey(rawRepresentation:)` wants exactly 32 bytes, and the Worker
// re-wraps the private seed into PKCS8 for WebCrypto. DER wrappers differ between languages;
// raw bytes do not.
const rawPublic = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32);
const rawPrivate = privateKey.export({ type: 'pkcs8', format: 'der' }).subarray(-32);

console.log('PUBLIC  (-> LicensePublicKey.base64, safe to commit)');
console.log(rawPublic.toString('base64'));
console.log();
console.log('PRIVATE (-> wrangler secret SIGNING_KEY, never commit)');
console.log(rawPrivate.toString('base64'));
console.log();
console.log('Verify they are a pair before shipping:  node keygen.mjs --selftest');

if (process.argv.includes('--selftest')) {
  const message = Buffer.from('bluebubbles-license-selftest');
  const signature = crypto.sign(null, message, privateKey);
  const ok = crypto.verify(null, message, publicKey, signature);
  console.log(ok ? '\nselftest: OK' : '\nselftest: FAILED');
  process.exit(ok ? 0 : 1);
}
