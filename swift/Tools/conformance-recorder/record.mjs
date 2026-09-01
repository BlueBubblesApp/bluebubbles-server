#!/usr/bin/env node
//
// Conformance recorder.
//
// Sits in front of a running BlueBubbles (Electron) server and captures every HTTP
// request/response pair and the full Socket.IO frame transcript as golden fixtures. Those
// fixtures are what the Swift server is later diffed against, strictly in both directions.
//
// This is the single most important artifact of Phase 0: it is the only source of truth for
// what "unchanged behaviour" actually means, and it can only be produced against the real
// server on a real Mac.
//
// Zero dependencies — Node built-ins only, so it runs anywhere without an npm install.
//
// Usage:
//   node record.mjs --target http://localhost:1234 --out ../../Fixtures/http
//
// Then point a client (or curl, or the Flutter app) at the recorder's port instead of the
// server's. Every exchange is written to the fixture directory.
//
// See ../../docs/TESTING.md.

import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { pathToFileURL } from 'node:url';

// Query params and body/header fields that carry credentials. Replaced with a stable
// placeholder so a fixture corpus is safe to share and diff. The placeholder is stable so
// it does not itself become a spurious diff.
const SECRET_QUERY_PARAMS = ['guid', 'password', 'token'];
const SECRET_HEADERS = ['authorization', 'cookie', 'set-cookie', 'proxy-authorization'];
// Credentials that arrive in a BODY rather than a URL or a header. Redacting the query
// string and the Authorization header covered how a credential is SENT and missed how one is
// ISSUED: `POST /auth/register` answers with a `client_secret`, and `POST /auth/token` with
// an `access_token`, so a working enrollment wrote a live credential into the corpus. These
// are keys, matched wherever they appear, because the response nests them under `data`.
const SECRET_BODY_KEYS = new Set([
  'client_secret', 'access_token', 'refresh_token', 'secret', 'password', 'token',
  'auth_token', 'authtoken', 'private_key', 'api_key'
]);
const REDACTED = '__REDACTED__';

// PERSONAL DATA SCRUBBING (--scrub, on by default).
//
// A corpus recorded against a real Mac contains the operator's entire address book and the
// text of real conversations with real people. This repository is public, so committing that
// verbatim would publish third parties' personal data — and the harness does not need it.
//
// What the parity diff actually asserts is SHAPE: which keys exist, what type each value is,
// how long the arrays are, and the handful of literal values that ARE the contract (status
// codes, `error.type` strings, the envelope's `message`). So scrubbing replaces personal
// VALUES while preserving all of that — same keys, same types, same lengths, same envelope.
//
// Two rules, and the second is the one that makes this worth doing rather than blanket-
// redacting everything:
//   1. Values under a key known to carry personal data are replaced by a same-typed stand-in.
//   2. Any string that LOOKS like a phone number or an email is replaced wherever it appears,
//      because addresses turn up inside GUIDs (`iMessage;-;+12025550143`) and free text.
// Everything else is left exactly as recorded, so a fixture still catches an envelope whose
// `message` drifted from "Ping received!" to "Success".
const PERSONAL_KEYS = new Set([
  'text', 'displayName', 'firstName', 'lastName', 'nickname', 'groupName',
  'address', 'transferName', 'filename', 'groupTitle', 'chatIdentifier',
  'uncanonicalizedId', 'lastAddressedHandle', 'lastSeenMessageGuid', 'avatar'
]);

const PHONE = /\+?\d[\d\s().-]{7,}\d/g;
// A canonical UUID is hex and hyphens, which is exactly the character set `PHONE` accepts
// after its first digit — so `9C97AE12-3456-7890-A58B-1E987EA00F18` had its digit runs
// overwritten and came out as `9C97AE+15555550100A58-8BB9-1E987EA00F18`. A UUID is an opaque
// machine identifier, not personal data, and mangling it corrupts the very shape the corpus
// exists to pin: a client that parses `group_uuid` cannot be tested against a value that is
// no longer a UUID.
//
// Matched FIRST and passed through unchanged, which is safe in the under-redaction direction
// because no phone number is 8-4-4-4-12 hex. A chat GUID like `iMessage;-;+12025550143` does
// not have that shape and is still scrubbed; a GUID that EMBEDS a UUID keeps the UUID and
// loses the address, which is exactly the split we want.
const UUID = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/;
// An ISO-8601 timestamp is digits and hyphens, which is the character set `PHONE` accepts —
// so `2026-08-30T15:36:06.267Z` had its DATE half overwritten and came out as
// `+15555550100T15:36:06.267Z`. Exactly the failure documented above for UUIDs, in a second
// shape, and it reached the committed corpus: 39 fixtures carry it across `scheduledFor`,
// `created`, `markedAsKnownDate`, `lastTUConversationCreatedDate` and `LSMD`.
//
// A timestamp is not personal data. It says when the recording ran, not who was in it, and
// the wire format's date handling is a thing the corpus is supposed to be able to prove.
const ISO_DATE =
  /\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)?/;

// A group chat's id is the third shape `PHONE` was eating, and the only one of the three
// that DOES have to be replaced — it names a real conversation. What it must not do is come
// out malformed. `any;+;chat123456789012345678` was stored as `any;+;chat+15555550100`,
// which is not a chat GUID at all: the grammar is `<service>;<kind>;<id>`, where the id is
// `+<E.164>` for a direct message and `chat<digits>` for a group. A client that parses a
// GUID could never have been tested against `chat+15555550100`, because no server emits it.
//
// So it is replaced with a well-formed stand-in of the same shape rather than passed
// through. The SERVICE half is real data and is never rewritten — it is `any` on macOS
// Tahoe and `iMessage` or `SMS` before it, and which one a server says is a thing the
// corpus is entitled to assert.
// A group's id comes in two shapes and BOTH are the id half of a chat GUID: the classic
// `chat` followed by digits, and a bare 32-character hex room name. The corpus holds
// `any;+;41c705874a...d3d7f35cf13e5` for the second, which `PHONE` had already chewed a
// nine-digit hole in.
//
// Both are REPLACED rather than preserved. Unlike a UUID — which this file passes through
// because it identifies a call or a message, not a person — a chat id maps to a real
// conversation with real participants, and the corpus is published. Replaced with a
// stand-in of the same shape, so the GUID stays parseable.
const GROUP_CHAT_ID = /chat\d{6,}|\b[0-9a-f]{32}\b/;

/// A stand-in for one group id: same shape, stable, and DISTINCT per input.
///
/// Not a single fixed placeholder, which is what a phone number gets. Phone numbers may all
/// collapse to `+15555550100` because nothing is keyed on them, but a chat id IS part of the
/// URL, and the fixture filename is derived from the URL — so collapsing every group to one
/// id would make `/chat/<a>/leave` and `/chat/<b>/leave` the same fixture and let one
/// silently overwrite the other. Deriving from the input keeps distinct chats distinct.
///
/// A digest, not a counter, so it does not depend on the order requests were recorded in:
/// re-recording the same conversation twice has to produce the same fixture both times.
/// Irreversible in the way that matters — the input is 128 bits of hex, so the mapping
/// cannot be walked backwards by guessing.
function groupChatPseudonym(id) {
  const digest = crypto.createHash('sha1').update(id).digest('hex');
  if (!id.startsWith('chat')) return digest.slice(0, 32);
  return 'chat' + BigInt('0x' + digest.slice(0, 16)).toString().padStart(10, '0').slice(0, 10);
}

// Order is load-bearing: alternation is leftmost-first, so the shapes to PRESERVE are
// listed before the shape to replace. Anything the preserve list does not match is a phone.
const PRESERVED_OR_PHONE = new RegExp(
  `${UUID.source}|${ISO_DATE.source}|${GROUP_CHAT_ID.source}|${PHONE.source}`, 'g');
const PRESERVED_ONLY = new RegExp(`^(?:${UUID.source}|${ISO_DATE.source})$`);
const IS_GROUP_CHAT_ID = new RegExp(`^${GROUP_CHAT_ID.source}$`);
const EMAIL = /[\w.+-]+@[\w-]+\.[\w.]+/g;
// A link-local IPv6 address embeds the interface MAC via EUI-64, so `fe80::c4c1:b7ff:fe52:388f`
// is a hardware identifier for the machine that recorded the corpus. `server_info` returns the
// whole list. Matched on the `::` form rather than any colon-run so chat GUIDs are untouched.
const IPV6 = /\b(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}\b(?:%[0-9a-zA-Z]+)?/g;
// Stack traces in `server_logs` carry absolute paths, which name the operator's account and
// lay out their filesystem. The username is the part worth losing; the shape is not.
const HOME_PATH = /\/Users\/[^\/\s"']+/g;

/** Replaces personal substrings while keeping the surrounding shape (a chat GUID stays a chat GUID). */
function scrubString(value) {
  return value
    .replace(EMAIL, 'person@example.com')
    // One pass, not two. Replacing phones first and repairing UUIDs afterwards cannot work:
    // the digits are overwritten, not encoded, so the original is unrecoverable by the time
    // a second pass sees it. Alternation with UUID first means the scan reaches a UUID and
    // consumes it whole before `PHONE` can start inside it.
    .replace(PRESERVED_OR_PHONE, (match) => {
      if (PRESERVED_ONLY.test(match)) return match;
      if (IS_GROUP_CHAT_ID.test(match)) return groupChatPseudonym(match);
      return '+15555550100';
    });
}

/// The body-only rules.
///
/// Deliberately NOT part of `scrubString`, which also runs over request URLs and therefore
/// decides fixture FILENAMES. Widening that function renames the corpus on the next
/// recording and silently orphans every fixture already on disk — the recorder self-test
/// catches it, which is how this split was found. Bodies are the only place an IPv6 address
/// or an absolute home path has ever appeared.
function scrubBodyString(value) {
  return scrubString(value)
    .replace(IPV6, match => (match.includes('::') ? 'fe80::1' : match))
    .replace(HOME_PATH, '/Users/user');
}

function scrubValue(value, key) {
  if (value === null) return null;
  if (Array.isArray(value)) return value.map(v => scrubValue(v, key));
  if (typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = scrubValue(v, k);
    return out;
  }
  // A credential is replaced whole rather than scrubbed: unlike a name, no part of it is
  // shape worth preserving, and a partial redaction of a secret is still a leak.
  if (SECRET_BODY_KEYS.has(key)) return typeof value === 'string' ? REDACTED : value;
  if (typeof value !== 'string') return value;
  // A same-LENGTH-ish stand-in, not an empty string: a client-visible truncation rule would
  // otherwise look like it passed on a corpus that never exercised it.
  if (PERSONAL_KEYS.has(key)) return scrubString(value) === value ? 'REDACTED' : scrubBodyString(value);
  return scrubBodyString(value);
}

function scrubBody(body) {
  if (!body) return body;
  if (body.kind === 'json') return { ...body, value: scrubValue(body.value, null) };
  // TEXT BODIES ARE SCRUBBED TOO, and forgetting that leaked real addresses into the corpus.
  // A multipart/form-data request body is not JSON, so it lands here as `text` — and every
  // form field, including the `chatGuid` carrying somebody's email, was being written out
  // verbatim while the equivalent JSON request was cleaned. Anything that is not JSON and not
  // binary gets the same string pass the JSON leaves do.
  if (body.kind === 'text' && typeof body.value === 'string') {
    return { ...body, value: scrubBodyString(body.value) };
  }
  return body;
}

// Response headers that vary per request and would otherwise dominate every diff.
const VOLATILE_HEADERS = new Set([
  'date', 'content-length', 'etag', 'last-modified', 'x-response-time', 'connection', 'keep-alive'
]);

function parseArgs(argv) {
  const args = {
    target: 'http://localhost:1234', out: null, port: 1235, maxBody: 1024 * 1024,
    // On by default. Recording personal data is the surprising outcome, so it is the one that
    // has to be asked for.
    scrub: true
  };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const next = () => argv[++i];
    if (flag === '--target') args.target = next();
    else if (flag === '--out') args.out = next();
    else if (flag === '--port') args.port = Number(next());
    else if (flag === '--max-body') args.maxBody = Number(next());
    else if (flag === '--no-scrub') args.scrub = false;
    else if (flag === '--help' || flag === '-h') args.help = true;
  }
  return args;
}

function redactUrl(rawUrl, scrub = true) {
  const url = new URL(rawUrl, 'http://placeholder');
  for (const key of SECRET_QUERY_PARAMS) {
    if (url.searchParams.has(key)) url.searchParams.set(key, REDACTED);
  }
  const path = url.pathname + (url.search || '');
  // The PATH carries addresses too — `/api/v1/handle/person@example.com`,
  // `/api/v1/chat/any;-;+12025550143`. Scrubbing only bodies leaves them in the fixture, and
  // in its filename, which is derived from the path.
  return scrub ? scrubString(decodeURIComponent(path)) : path;
}

function redactHeaders(headers) {
  const out = {};
  for (const [key, value] of Object.entries(headers)) {
    const lower = key.toLowerCase();
    if (SECRET_HEADERS.includes(lower)) out[lower] = REDACTED;
    else if (!VOLATILE_HEADERS.has(lower)) out[lower] = value;
  }
  return out;
}

/**
 * Fixture filenames must be stable across runs so re-recording produces a reviewable diff
 * rather than a churn of new files. Derived from method + path shape + a hash of the query
 * keys, deliberately excluding values (which contain GUIDs and timestamps).
 */
function fixtureName(method, rawUrl, scrub = true, status = null) {
  const url = new URL(scrub ? decodeURIComponent(rawUrl) : rawUrl, 'http://placeholder');
  const shape = url.pathname
    .split('/')
    .filter(Boolean)
    // Classified BEFORE scrubbing, then scrubbed only if it survives as a literal.
    //
    // `PHONE` matches the digit-and-hyphen runs inside a UUID, so scrubbing the whole path
    // first turned `A1B2C3D4-1111-2222-3333-444455556666` into `A1B2C3D+15555550100` — no
    // longer id-shaped, so the collapse never fired and two different GUIDs on one route
    // produced two fixtures. That is the opposite of what collapsing is for, and it is why
    // the corpus contains a name like `..._allowlist_AF4D6D+15555550100AE-BDB7-...`.
    //
    // Ordering it this way loses nothing: a segment that collapses is GONE, so there is
    // nothing left in it to redact, and every segment that does NOT collapse still gets the
    // same scrub it got before.
    .map((segment) => {
      if (/^[0-9a-fA-F-]{8,}$/.test(segment) || /^\d+$/.test(segment)) return ':id';
      return scrub ? scrubString(segment) : segment;
    })
    .join('_');
  const queryKeys = [...url.searchParams.keys()].sort().join(',');
  const suffix = queryKeys
    ? '-' + crypto.createHash('sha1').update(queryKeys).digest('hex').slice(0, 6)
    : '';
  // The STATUS is part of the name, because a 200 and a 401 for the same path are two
  // different fixtures and both are contract — the status/error-type pairing is one of the
  // invariants this corpus exists to pin. Without it the error cases silently overwrote the
  // success cases they were recorded alongside, which is how the first corpus ended up with a
  // 401 stored as `get_api_v1_ping`.
  const statusPart = status == null ? '' : `-${status}`;
  return `${method.toLowerCase()}_${shape || 'root'}${suffix}${statusPart}.json`;
}

function tryParseJson(buffer, contentType) {
  if (!contentType || !contentType.includes('application/json')) return null;
  try {
    return JSON.parse(buffer.toString('utf8'));
  } catch {
    return null;
  }
}

/** Content types whose BYTES are not the contract and must never be transcribed into a fixture. */
function isBinaryContentType(contentType) {
  if (!contentType) return false;
  const type = contentType.toLowerCase();
  return /^(image|video|audio|font)\//.test(type)
    || type.startsWith('application/octet-stream')
    || type.startsWith('application/pdf')
    || type.startsWith('application/zip');
}

function summarizeBody(buffer, contentType, maxBody) {
  if (buffer.length === 0) return { kind: 'empty' };
  const json = tryParseJson(buffer, contentType);
  if (json !== null) return { kind: 'json', value: json };
  // Checked BEFORE the size test. An attachment download under the size cap was being
  // recorded as `text`, which put a real photo's bytes into a committed fixture as mojibake —
  // the size cap is about keeping fixtures reviewable, not about what is safe to store.
  if (isBinaryContentType(contentType) || buffer.length > maxBody) {
    // Attachment downloads are large and their bytes are not the contract. Record the
    // shape instead so the fixture stays reviewable.
    return {
      kind: 'binary',
      byteLength: buffer.length,
      sha256: crypto.createHash('sha256').update(buffer).digest('hex')
    };
  }
  return { kind: 'text', value: buffer.toString('utf8') };
}

function writeFixture(dir, name, payload) {
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, name);
  fs.writeFileSync(file, JSON.stringify(payload, null, 2) + '\n');
  return file;
}

function startRecorder(args) {
  const target = new URL(args.target);
  const httpDir = path.join(args.out, 'http');
  const socketDir = path.join(args.out, 'socket');
  let recorded = 0;

  const server = http.createServer((clientReq, clientRes) => {
    const chunks = [];
    clientReq.on('data', (chunk) => chunks.push(chunk));
    clientReq.on('end', () => {
      const requestBody = Buffer.concat(chunks);

      const proxyReq = http.request(
        {
          hostname: target.hostname,
          port: target.port,
          path: clientReq.url,
          method: clientReq.method,
          headers: { ...clientReq.headers, host: target.host }
        },
        (proxyRes) => {
          const responseChunks = [];
          proxyRes.on('data', (chunk) => responseChunks.push(chunk));
          proxyRes.on('end', () => {
            const responseBody = Buffer.concat(responseChunks);

            // Socket.IO polling traffic is captured by the socket transcript, not as HTTP.
            const isEngineIO = clientReq.url.startsWith('/socket.io/');
            if (!isEngineIO) {
              const fixture = {
                request: {
                  method: clientReq.method,
                  path: redactUrl(clientReq.url, args.scrub),
                  headers: redactHeaders(clientReq.headers),
                  body: (() => {
                    const summarized = summarizeBody(
                      requestBody, clientReq.headers['content-type'], args.maxBody
                    );
                    return args.scrub ? scrubBody(summarized) : summarized;
                  })()
                },
                response: {
                  status: proxyRes.statusCode,
                  headers: redactHeaders(proxyRes.headers),
                  body: (() => {
                    const summarized = summarizeBody(
                      responseBody, proxyRes.headers['content-type'], args.maxBody
                    );
                    return args.scrub ? scrubBody(summarized) : summarized;
                  })()
                },
                recordedAt: new Date().toISOString()
              };
              const name = fixtureName(
                clientReq.method, clientReq.url, args.scrub, proxyRes.statusCode
              );
              writeFixture(httpDir, name, fixture);
              recorded += 1;
              process.stdout.write(
                `[http] ${clientReq.method} ${redactUrl(clientReq.url, args.scrub)} -> ${proxyRes.statusCode}  (${name})\n`
              );
            } else {
              const transcriptFile = path.join(socketDir, 'polling-transcript.jsonl');
              fs.mkdirSync(socketDir, { recursive: true });
              fs.appendFileSync(
                transcriptFile,
                JSON.stringify({
                  transport: 'polling',
                  method: clientReq.method,
                  path: redactUrl(clientReq.url, args.scrub),
                  status: proxyRes.statusCode,
                  payload: responseBody.toString('utf8'),
                  at: new Date().toISOString()
                }) + '\n'
              );
              process.stdout.write(`[eio ] ${clientReq.method} ${redactUrl(clientReq.url, args.scrub)}\n`);
            }

            clientRes.writeHead(proxyRes.statusCode, proxyRes.headers);
            clientRes.end(responseBody);
          });
        }
      );

      proxyReq.on('error', (error) => {
        process.stderr.write(`[err ] ${error.message}\n`);
        clientRes.writeHead(502);
        clientRes.end('recorder: upstream unreachable');
      });

      proxyReq.end(requestBody);
    });
  });

  // WebSocket upgrade. Frames are copied through verbatim and appended to the transcript in
  // both directions, because the Socket.IO handshake and frame sequence are exactly what the
  // Swift implementation has to reproduce.
  server.on('upgrade', (req, clientSocket, head) => {
    const upstream = net.connect(Number(target.port), target.hostname, () => {
      const headerLines = Object.entries(req.headers)
        .map(([key, value]) => `${key}: ${value}`)
        .join('\r\n');
      upstream.write(
        `${req.method} ${req.url} HTTP/1.1\r\n${headerLines}\r\n\r\n`
      );
      if (head && head.length) upstream.write(head);

      fs.mkdirSync(socketDir, { recursive: true });
      const transcriptFile = path.join(socketDir, 'websocket-transcript.jsonl');
      const append = (direction, buffer) => {
        fs.appendFileSync(
          transcriptFile,
          JSON.stringify({
            transport: 'websocket',
            direction,
            base64: buffer.toString('base64'),
            at: new Date().toISOString()
          }) + '\n'
        );
      };

      clientSocket.on('data', (buffer) => {
        append('client->server', buffer);
        upstream.write(buffer);
      });
      upstream.on('data', (buffer) => {
        append('server->client', buffer);
        clientSocket.write(buffer);
      });

      process.stdout.write(`[ws  ] upgrade ${redactUrl(req.url, args.scrub)}\n`);
    });

    const teardown = () => {
      upstream.destroy();
      clientSocket.destroy();
    };
    upstream.on('error', teardown);
    clientSocket.on('error', teardown);
    upstream.on('close', teardown);
    clientSocket.on('close', teardown);
  });

  server.listen(args.port, () => {
    if (args.quiet) return;
    process.stdout.write(
      `Conformance recorder listening on http://localhost:${args.port}\n` +
        `  upstream: ${args.target}\n` +
        `  fixtures: ${path.resolve(args.out)}\n\n` +
        `Point a client at the recorder's port instead of the server's, then exercise it.\n` +
        `Ctrl-C when done.\n\n`
    );
  });

  process.on('SIGINT', () => {
    process.stdout.write(`\nRecorded ${recorded} HTTP exchanges.\n`);
    process.exit(0);
  });

  return server;
}

// Only start when invoked directly, so selftest.mjs can import the pure helpers.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || !args.out) {
    process.stdout.write(
      'Conformance recorder — captures golden fixtures from the running Electron server.\n\n' +
        'Usage:\n' +
        '  node record.mjs --out <dir> [--target http://localhost:1234] [--port 1235]\n\n' +
        'Options:\n' +
        '  --out <dir>       Fixture output directory (required)\n' +
        '  --target <url>    Upstream server (default http://localhost:1234)\n' +
        '  --port <n>        Port to listen on (default 1235)\n' +
        '  --max-body <n>    Bodies larger than this are recorded as a hash (default 1MiB)\n'
    );
    process.exit(args.help ? 0 : 1);
  }
  startRecorder(args);
}

export {
  parseArgs, redactUrl, redactHeaders, fixtureName, summarizeBody, startRecorder, REDACTED,
  scrubValue, scrubBody, scrubString, scrubBodyString, isBinaryContentType
};
