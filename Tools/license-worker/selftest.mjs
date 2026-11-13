#!/usr/bin/env node
//
// Mints a token exactly as the Worker does, and prints it with its public key so the Swift
// verifier can be pointed at it.
//
// This is the check worth having: the Worker and `TokenVerifier` are in different languages
// and agree on four things by convention alone — base64url without padding, the signature
// covering `header.claims` and not the whole token, raw 32-byte keys rather than DER, and
// claim spellings. Each is silent when wrong: the token looks fine and fails to verify.
//
//   node selftest.mjs | swift run ...   (see README)

import crypto from 'node:crypto';

const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
const rawPublic = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32);
const seed = privateKey.export({ type: 'pkcs8', format: 'der' }).subarray(-32);

const b64url = (b) =>
  Buffer.from(b).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

const now = Math.floor(Date.now() / 1000);
const claims = {
  v: 1,
  sub: 'lk_selftest',
  tier: 'pro',
  rank: 1,
  feats: [],
  // A real 64-char hex digest, because the Worker refuses anything else.
  machine: crypto.createHash('sha256').update('selftest-machine').digest('hex'),
  iat: now,
  exp: now + 7 * 86_400,
  sub_end: now + 30 * 86_400,
  // A subscription, so no `perp`. The lifetime variant sets it; see worker.js.
  jti: crypto.randomUUID(),
};

// The same PKCS8 re-wrap the Worker does, from the same raw seed, so this exercises that path
// rather than Node's own key object.
const pkcs8 = Buffer.concat([
  Buffer.from('302e020100300506032b657004220420', 'hex'),
  seed,
]);
const rewrapped = crypto.createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' });

const signing = `${b64url(JSON.stringify({ alg: 'EdDSA', typ: 'JWT' }))}.${b64url(JSON.stringify(claims))}`;
const signature = crypto.sign(null, Buffer.from(signing, 'utf8'), rewrapped);
const token = `${signing}.${b64url(signature)}`;

console.log(JSON.stringify({ publicKey: rawPublic.toString('base64'), token, machine: claims.machine }));
