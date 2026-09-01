#!/usr/bin/env node
//
// Cross-checks the typedstream fixtures against node-typedstream, the reference decoder.
//
// The fixtures are ENCODED by typedstream_vectors.py, so on their own they only prove that
// the generator agrees with itself. Decoding them with an independent implementation is what
// makes them evidence: if node-typedstream reads back the expected text, the format
// understanding is confirmed and the Swift decoder has a trustworthy target.
//
//   node verify.mjs [path-to-typedstream-vectors.json]

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const defaultPath = path.join(
  here, '..', '..', 'Tests', 'ProtocolTests', 'ProtocolFixtures', 'typedstream-vectors.json'
);
const fixturePath = process.argv[2] || defaultPath;

let typedstream;
try {
  typedstream = await import(path.join(here, 'node_modules', 'node-typedstream', 'dist', 'index.js'));
} catch {
  process.stderr.write('node-typedstream not installed. Run: npm install node-typedstream\n');
  process.exit(1);
}

const fixtures = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
let passed = 0;
let failed = 0;

process.stdout.write('typedstream fixture cross-check (reference: node-typedstream)\n');

for (const vector of fixtures.vectors) {
  const bytes = Buffer.from(vector.base64, 'base64');

  try {
    const decoded = typedstream.Unarchiver.open(bytes).decodeAll();
    const flat = JSON.stringify(decoded);

    // The reference returns the full object graph. We assert the expected text is present
    // in it rather than matching a shape, because the point here is that the BYTES are a
    // valid archive containing that string — the Swift tests assert extraction precisely.
    const expected = vector.expectedText;
    const found = expected === '' ? true : flat.includes(JSON.stringify(expected).slice(1, -1));

    if (found) {
      passed += 1;
      process.stdout.write(`  ok    ${vector.name}\n`);
    } else {
      failed += 1;
      process.stdout.write(`  FAIL  ${vector.name}: expected text not found in decode\n`);
      process.stdout.write(`        decoded: ${flat.slice(0, 200)}\n`);
    }
  } catch (error) {
    failed += 1;
    process.stdout.write(`  FAIL  ${vector.name}: ${error.message}\n`);
  }
}

process.stdout.write(`\n${passed} passed, ${failed} failed\n`);
if (failed > 0) {
  process.stdout.write(
    'A failure here means the generator and the reference disagree about the format. ' +
      'Fix the generator before trusting the Swift decoder against these fixtures.\n'
  );
}
process.exit(failed === 0 ? 0 : 1);
