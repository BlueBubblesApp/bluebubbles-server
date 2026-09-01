#!/usr/bin/env node
//
// Self-test for the conformance recorder.
//
// The recorder handles credentials, so its redaction has to be correct before anyone points
// it at a real server with real messages. This runs on every PR (see swift-pr.yml) and needs
// no network, no server, and no dependencies.
//
// Also exercises the recorder end to end against a throwaway upstream, because the parts
// most likely to break — proxying, fixture naming, body classification — are not pure.

import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  redactUrl,
  redactHeaders,
  fixtureName,
  summarizeBody,
  startRecorder,
  scrubString,
  scrubBody,
  REDACTED
} from './record.mjs';

let passed = 0;
function test(name, fn) {
  try {
    fn();
    passed += 1;
    process.stdout.write(`  ok  ${name}\n`);
  } catch (error) {
    process.stderr.write(`  FAIL  ${name}\n    ${error.message}\n`);
    process.exitCode = 1;
  }
}

async function asyncTest(name, fn) {
  try {
    await fn();
    passed += 1;
    process.stdout.write(`  ok  ${name}\n`);
  } catch (error) {
    process.stderr.write(`  FAIL  ${name}\n    ${error.message}\n`);
    process.exitCode = 1;
  }
}

process.stdout.write('conformance-recorder self-test\n');

// --- Redaction -------------------------------------------------------------------------
// All three auth aliases the server accepts must be caught. Missing one would leak a
// password into a fixture corpus that gets committed or shared.

test('redacts the guid auth param', () => {
  assert.equal(redactUrl('/api/v1/ping?guid=hunter2'), `/api/v1/ping?guid=${REDACTED}`);
});

test('redacts the password auth param', () => {
  assert.equal(redactUrl('/api/v1/ping?password=hunter2'), `/api/v1/ping?password=${REDACTED}`);
});

test('redacts the token auth param', () => {
  assert.equal(redactUrl('/api/v1/ping?token=hunter2'), `/api/v1/ping?token=${REDACTED}`);
});

test('preserves non-secret params so they still diff', () => {
  const result = redactUrl('/api/v1/chat/query?limit=100&guid=secret');
  assert.ok(result.includes('limit=100'));
  assert.ok(!result.includes('secret'));
});

test('leaves a URL with no secrets untouched', () => {
  assert.equal(redactUrl('/api/v1/ping'), '/api/v1/ping');
});

test('redacts the Authorization header', () => {
  const headers = redactHeaders({ Authorization: 'Bearer abc', 'content-type': 'application/json' });
  assert.equal(headers.authorization, REDACTED);
  assert.equal(headers['content-type'], 'application/json');
});

test('drops volatile headers that would dominate every diff', () => {
  const headers = redactHeaders({ date: 'now', 'content-length': '12', 'x-custom': 'keep' });
  assert.ok(!('date' in headers));
  assert.ok(!('content-length' in headers));
  assert.equal(headers['x-custom'], 'keep');
});

// --- Fixture naming --------------------------------------------------------------------
// Names must be stable across runs, or re-recording produces churn instead of a diff.

test('fixture names are stable for the same request', () => {
  assert.equal(
    fixtureName('GET', '/api/v1/ping?guid=a'),
    fixtureName('GET', '/api/v1/ping?guid=b')
  );
});

test('identifiers in the path collapse to :id', () => {
  const withGuid = fixtureName('GET', '/api/v1/chat/A1B2C3D4-1111-2222-3333-444455556666');
  const withOther = fixtureName('GET', '/api/v1/chat/FFFFFFFF-9999-8888-7777-666655554444');
  assert.equal(withGuid, withOther);
  assert.ok(withGuid.includes('id'));
});

test('numeric path segments collapse too', () => {
  assert.equal(
    fixtureName('DELETE', '/api/v1/contact/1'),
    fixtureName('DELETE', '/api/v1/contact/99999')
  );
});

test('different query key sets produce different fixtures', () => {
  assert.notEqual(
    fixtureName('POST', '/api/v1/chat/query?limit=1'),
    fixtureName('POST', '/api/v1/chat/query?offset=1')
  );
});

test('method is part of the name', () => {
  assert.notEqual(fixtureName('GET', '/api/v1/webhook'), fixtureName('POST', '/api/v1/webhook'));
});

// --- Body classification ---------------------------------------------------------------

// Scrubbing had NO coverage here, which is how a redactor that quietly corrupted every UUID
// in the corpus shipped and stayed. The `:id` test above only caught it because the damage
// happened to reach a filename.

test('a real phone number is still replaced', () => {
  assert.equal(scrubString('call +1 (555) 123-4567 now'), 'call +15555550100 now');
});

test('an address inside a chat GUID is still replaced', () => {
  assert.equal(scrubString('iMessage;-;+12025550143'), 'iMessage;-;+15555550100');
  assert.equal(scrubString('iMessage;-;someone@example.org'), 'iMessage;-;person@example.com');
});

test('a group chat id is replaced but stays a well-formed chat GUID', () => {
  // The grammar is `<service>;<kind>;<id>`. Replacing the id with a phone number produced
  // `any;+;chat+15555550100`, which no server emits and no client can parse.
  const out = scrubString('any;+;chat123456789012345678');
  assert.match(out, /^any;\+;chat\d{10}$/);
  assert.ok(!out.includes('123456789012345678'), 'the real id must not survive');
});

test('group ids are pseudonymised distinctly, not collapsed', () => {
  // Phone numbers may all collapse to one placeholder; chat ids may not. The fixture
  // FILENAME is derived from the URL, so collapsing two groups to one id would make
  // `/chat/<a>/leave` and `/chat/<b>/leave` the same file and let one overwrite the other.
  const a = scrubString('any;+;49d0b618798a414c9a74291223a99b6e');
  const b = scrubString('any;+;621276cd60bf47129edc6273b6bf76c2');
  assert.notEqual(a, b, 'two different rooms must not scrub to the same id');
  assert.notEqual(scrubString('any;+;chat111111111111'), scrubString('any;+;chat222222222222'));
});

test('a group id pseudonym is stable across calls and recordings', () => {
  // A digest rather than a counter, so it does not depend on recording order: re-recording
  // the same conversation has to land on the same fixture name both times.
  assert.equal(
    scrubString('any;+;49d0b618798a414c9a74291223a99b6e'),
    scrubString('any;+;49d0b618798a414c9a74291223a99b6e')
  );
});

test('a hex room-name group id is replaced and stays 32 hex', () => {
  // The other group-id shape. `any;+;41c705874a...` is as much a chat GUID as
  // `any;+;chat123...`, and PHONE had chewed a nine-digit hole in it.
  const out = scrubString('any;+;41c705874abc12d3d7f35cf13e5aabbc');
  assert.match(out, /^any;\+;[0-9a-f]{32}$/);
  assert.ok(!out.includes('41c705874abc12d3d7f35cf13e5aabbc'), 'the real room name must not survive');
});

test('the service half of a GUID is never rewritten', () => {
  // `any` on Tahoe, `iMessage` or `SMS` before it. Which one a server says is contract.
  assert.ok(scrubString('iMessage;+;chat123456789012345678').startsWith('iMessage;+;'));
  assert.ok(scrubString('SMS;-;+15551234567').startsWith('SMS;-;'));
  assert.ok(scrubString('any;-;+15551234567').startsWith('any;-;'));
});

test('a direct-message GUID keeps its +E.164 id shape', () => {
  assert.match(scrubString('any;-;+15551234567'), /^any;-;\+\d+$/);
});

test('a canonical UUID survives scrubbing intact', () => {
  // The digit runs between the hyphens are exactly what PHONE used to eat.
  const uuid = '9C97AE12-3456-7890-A58B-1E987EA00F18';
  assert.equal(scrubString(uuid), uuid);
});

test('a UUID of nothing but digits survives too', () => {
  const uuid = '12345678-1234-5678-1234-567812345678';
  assert.equal(scrubString(uuid), uuid);
});

// Same failure as the UUID above, in a second shape, and this one reached the corpus: a
// timestamp is digits and hyphens, so `PHONE` ate the DATE half of every ISO-8601 string
// and 39 committed fixtures carry `+15555550100T15:36:06.267Z` where a date belongs.
//
// A timestamp is not personal data — it says when the recording ran, not who was in it —
// and date handling is one of the things the corpus exists to be able to prove.
test('an ISO-8601 timestamp survives scrubbing intact', () => {
  for (const stamp of [
    '2026-08-30T15:36:06.267Z',
    '2026-08-30T15:36:06Z',
    '2026-08-30',
    '2026-08-30T15:36:06.267+02:00',
    '2026-08-30 15:36:06',
  ]) {
    assert.equal(scrubString(stamp), stamp, `mangled ${stamp}`);
  }
});

test('a timestamp inside a larger value keeps its date half', () => {
  assert.equal(
    scrubString('{"scheduledFor":"2026-08-30T15:36:06.267Z"}'),
    '{"scheduledFor":"2026-08-30T15:36:06.267Z"}');
});

test('a real phone number is still scrubbed when a date is nearby', () => {
  const scrubbed = scrubString('called +1 415 555 8888 at 2026-08-30T15:36:06.267Z');
  assert.ok(scrubbed.includes('2026-08-30T15:36:06.267Z'), 'the date should survive');
  assert.ok(!scrubbed.includes('415'), 'the number should not');
});

test('a GUID embedding a UUID keeps the UUID and loses the address', () => {
  assert.equal(
    scrubString('p:0/9C97AE12-3456-7890-A58B-1E987EA00F18;-;+12025550143'),
    'p:0/9C97AE12-3456-7890-A58B-1E987EA00F18;-;+15555550100'
  );
});

test('a UUID in a response body is not mangled', () => {
  const body = scrubBody({ kind: 'json', value: { link: { group_uuid: '9C97AE12-3456-7890-A58B-1E987EA00F18' } } });
  assert.equal(body.value.link.group_uuid, '9C97AE12-3456-7890-A58B-1E987EA00F18');
});

test('two different GUIDs on one route still collapse to one fixture', () => {
  // The end the :id collapse exists for, asserted as a property rather than a spelling.
  assert.equal(
    fixtureName('DELETE', '/api/v2/server/security/allowlist/9C97AE12-3456-7890-A58B-1E987EA00F18', true, 200),
    fixtureName('DELETE', '/api/v2/server/security/allowlist/AF4D6D01-2222-3333-4444-2427BE0EE756', true, 200)
  );
});

test('empty bodies are marked empty', () => {
  assert.equal(summarizeBody(Buffer.alloc(0), 'application/json', 1024).kind, 'empty');
});

test('JSON bodies are parsed, not stringified', () => {
  const body = summarizeBody(Buffer.from('{"status":200}'), 'application/json', 1024);
  assert.equal(body.kind, 'json');
  assert.equal(body.value.status, 200);
});

test('malformed JSON degrades to text rather than throwing', () => {
  assert.equal(summarizeBody(Buffer.from('{oops'), 'application/json', 1024).kind, 'text');
});

test('large bodies are hashed instead of inlined', () => {
  const body = summarizeBody(Buffer.alloc(4096, 7), 'application/octet-stream', 1024);
  assert.equal(body.kind, 'binary');
  assert.equal(body.byteLength, 4096);
  assert.match(body.sha256, /^[0-9a-f]{64}$/);
});

// --- End to end ------------------------------------------------------------------------

/** Issues a real request through the recorder and returns the proxied response body. */
function get(port, requestPath) {
  return new Promise((resolve, reject) => {
    const req = http.get({ host: '127.0.0.1', port, path: requestPath }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () =>
        resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') })
      );
    });
    req.on('error', reject);
  });
}

await asyncTest('proxies a real request end to end and writes a redacted fixture', async () => {
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bb-recorder-'));
  let sawCredential = false;

  // Stand-in for the Electron server. Asserts the credential still reaches upstream —
  // redaction must apply to the recorded fixture, never to the proxied request, or the
  // recorder would break the very server it is observing.
  const upstream = http.createServer((req, res) => {
    if (req.url.includes('hunter2')) sawCredential = true;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ status: 200, message: 'Success', data: 'pong' }));
  });
  await new Promise((resolve) => upstream.listen(0, '127.0.0.1', resolve));

  const recorder = startRecorder({
    target: `http://127.0.0.1:${upstream.address().port}`,
    out: outDir,
    port: 0,
    maxBody: 1024 * 1024,
    quiet: true
  });
  await new Promise((resolve) => recorder.once('listening', resolve));

  const response = await get(recorder.address().port, '/api/v1/ping?guid=hunter2');

  assert.equal(response.status, 200, 'the proxied response should pass through unchanged');
  assert.ok(response.body.includes('pong'), 'the client should receive the upstream body verbatim');
  assert.ok(sawCredential, 'the credential must reach upstream unredacted');

  // The recorded name carries the STATUS, so predicting it here has to as well. Leaving it
  // off asserted against a filename the recorder has not written since status became part of
  // the name, and the check failed for a reason that had nothing to do with proxying.
  const file = path.join(outDir, 'http', fixtureName('GET', '/api/v1/ping?guid=hunter2', true, 200));
  assert.ok(fs.existsSync(file), `expected a fixture at ${file}`);

  const written = fs.readFileSync(file, 'utf8');
  assert.ok(!written.includes('hunter2'), 'the fixture must not contain the credential');
  assert.ok(written.includes(REDACTED));

  const parsed = JSON.parse(written);
  assert.equal(parsed.response.status, 200);
  assert.equal(parsed.response.body.kind, 'json');
  assert.equal(parsed.response.body.value.data, 'pong');
  assert.ok(!('date' in parsed.response.headers), 'volatile headers should be dropped');

  recorder.close();
  upstream.close();
  fs.rmSync(outDir, { recursive: true, force: true });
});

await asyncTest('routes socket.io traffic to the transcript, not the HTTP corpus', async () => {
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bb-recorder-'));

  const upstream = http.createServer((req, res) => {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('0{"sid":"abc","upgrades":["websocket"],"pingInterval":60000}');
  });
  await new Promise((resolve) => upstream.listen(0, '127.0.0.1', resolve));

  const recorder = startRecorder({
    target: `http://127.0.0.1:${upstream.address().port}`,
    out: outDir,
    port: 0,
    maxBody: 1024 * 1024,
    quiet: true
  });
  await new Promise((resolve) => recorder.once('listening', resolve));

  await get(recorder.address().port, '/socket.io/?EIO=4&transport=polling');

  const transcript = path.join(outDir, 'socket', 'polling-transcript.jsonl');
  assert.ok(fs.existsSync(transcript), 'engine.io polling should land in the transcript');
  assert.ok(
    !fs.existsSync(path.join(outDir, 'http')),
    'engine.io traffic must not pollute the HTTP fixture corpus'
  );

  const entry = JSON.parse(fs.readFileSync(transcript, 'utf8').trim());
  assert.equal(entry.transport, 'polling');
  assert.ok(entry.payload.includes('pingInterval'), 'the handshake payload must be captured');

  recorder.close();
  upstream.close();
  fs.rmSync(outDir, { recursive: true, force: true });
});

process.stdout.write(`\n${passed} checks passed\n`);
if (process.exitCode) process.stdout.write('SELF-TEST FAILED\n');
// The recorder's HTTP servers keep the loop alive; exit explicitly.
process.exit(process.exitCode ?? 0);
