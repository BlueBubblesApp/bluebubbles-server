#!/usr/bin/env node
//  import-limneos.mjs
//  Turns the JSON that `limneos-scrape.js` downloads into `docs/headers/macos-15.6/*.h`.
//
//  The scrape banks raw HTML pages; this extracts the class dump out of each one and writes
//  it in the same shape as the files already in that directory, banner and all. It is the
//  half of the stopgap that runs on this machine, so it can be re-run and diffed rather than
//  hand-transcribed — which is how the first 63 got there and is not repeatable.
//
//  Usage:
//     ./import-limneos.mjs ~/Downloads/limneos-macos-15.6-part2.json
//     ./import-limneos.mjs --dry-run <file>     report what it would write, write nothing
//     ./import-limneos.mjs --out DIR <file>     somewhere other than docs/headers/macos-15.6
//
//  It REFUSES to overwrite a file produced by dump-headers.sh. A real runtime dump beats a
//  scraped one and the whole point of `docs/headers/README.md` is that the weaker source must
//  never silently replace the stronger.

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../..');

const args = process.argv.slice(2);
let dryRun = false;
let outDir = join(ROOT, 'docs/headers/macos-15.6');
let input = null;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--dry-run') dryRun = true;
  else if (args[i] === '--out') outDir = args[++i];
  else if (args[i] === '-h' || args[i] === '--help') {
    console.log(readFileSync(fileURLToPath(import.meta.url), 'utf8')
      .split('\n').slice(1, 18).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
    process.exit(0);
  } else input = args[i];
}
if (!input) { console.error('error: no JSON file given (try --help)'); process.exit(1); }

// ---------------------------------------------------------------------------
// Extracting the dump out of a page
// ---------------------------------------------------------------------------

const ENTITIES = { '&lt;': '<', '&gt;': '>', '&amp;': '&', '&quot;': '"', '&#39;': "'", '&nbsp;': ' ' };
const decode = (s) =>
  s.replace(/&(lt|gt|amp|quot|#39|nbsp);/g, (m) => ENTITIES[m])
   .replace(/&#(\d+);/g, (_, d) => String.fromCharCode(+d));

/// Pulls the header text out of one page.
///
/// Two strategies, and the ORDER matters. `<pre>` is how the site presents a dump, so it is
/// tried first and trusted. The fallback — first `@interface`/`@protocol` through the last
/// `@end` — is deliberately narrow: a whole-page tag strip would sweep in the navigation and
/// the footer, and a header with a site menu in it looks plausible enough to get committed.
function extract(html) {
  const pre = [...html.matchAll(/<pre[^>]*>([\s\S]*?)<\/pre>/gi)]
    .map((m) => decode(m[1].replace(/<[^>]+>/g, '')))
    .filter((t) => /@interface|@protocol/.test(t))
    .sort((a, b) => b.length - a.length)[0];
  if (pre) return { text: pre.trim(), how: 'pre' };

  const stripped = decode(html.replace(/<script[\s\S]*?<\/script>/gi, '')
                              .replace(/<style[\s\S]*?<\/style>/gi, '')
                              .replace(/<br\s*\/?>/gi, '\n')
                              .replace(/<\/(div|p|li|tr)>/gi, '\n')
                              .replace(/<[^>]+>/g, ''));
  const start = stripped.search(/@(interface|protocol)\b/);
  const end = stripped.lastIndexOf('@end');
  if (start === -1 || end === -1 || end < start) return null;
  return { text: stripped.slice(start, end + 4).trim(), how: 'fallback' };
}

/// The provenance banner every file in this directory carries.
///
/// Copied deliberately rather than abbreviated: it is the thing that stops a reader treating
/// a scraped header as a runtime dump, and it has to be on EVERY file because that is where
/// somebody reads it — not in the README they did not open.
function banner(name, framework, how) {
  return [
    '// macOS 15.6 (Sequoia, build 24G84).',
    '//',
    '// NOT produced by swift/Tools/private-api. Third-party class-dump of the shipping binaries,',
    '// transcribed from developer.limneos.net. It differs from macos-26.5.2/ in two ways that',
    '// change how it reads — see docs/headers/README.md, "macOS 15.6 is a borrowed dump":',
    '//   - read from the Mach-O in the dyld shared cache, not from the Objective-C runtime',
    '//   - the NATIVE macOS framework, not the /System/iOSSupport (Catalyst) copy that',
    '//     Messages.app loads',
    '// Superseded by Tools/private-api/dump-headers.sh run on macOS 15.',
    '//',
    '// Dumped with classdump-dyld 3.0, arm64e Macmini9,1.',
    `// Imported by Tools/private-api/import-limneos.mjs on ${new Date().toISOString().slice(0, 10)}`,
    how === 'fallback'
      ? '// NOTE: no <pre> block on the source page; text recovered by tag-stripping. Spot-check it.'
      : null,
    '//',
    `// Image: /System/Library/PrivateFrameworks/${framework}/Versions/A/${framework.replace(/\.framework$/, '')}`,
    '// Image source: dyld_shared_cache (arm64e)',
    '',
    '',
  ].filter((l) => l !== null).join('\n');
}

// ---------------------------------------------------------------------------

const payload = JSON.parse(readFileSync(input, 'utf8'));
const entries = payload.headers ?? payload;

if (!dryRun && !existsSync(outDir)) mkdirSync(outDir, { recursive: true });

const existing = existsSync(outDir) ? readdirSync(outDir) : [];
const wrote = [], skipped = [], refused = [], failed = [];

for (const [name, entry] of Object.entries(entries)) {
  if (entry.status && entry.status !== 'ok') { skipped.push(`${name} (${entry.status})`); continue; }
  if (!entry.html) { skipped.push(`${name} (empty)`); continue; }

  const file = entry.header ?? `${name}.h`;

  // Never clobber a real runtime dump. `dump-headers.sh` stamps its own first line; if a
  // file here carries it, a Sequoia machine has already done better than this scrape.
  if (existing.includes(file)) {
    const head = readFileSync(join(outDir, file), 'utf8').slice(0, 200);
    if (head.includes('Generated by swift/Tools/private-api')) {
      refused.push(`${file} — a runtime dump is already here; not overwriting`);
      continue;
    }
  }

  const got = extract(entry.html);
  if (!got) { failed.push(`${name} — no @interface/@protocol found in the page`); continue; }

  const text = banner(name, entry.framework ?? 'IMCore.framework', got.how) + got.text + '\n';
  if (!dryRun) writeFileSync(join(outDir, file), text);
  wrote.push(`${file}  (${got.text.length} bytes${got.how === 'fallback' ? ', FALLBACK' : ''})`);
}

const say = (label, list) => { if (list.length) { console.log(`\n${label}`); list.forEach((l) => console.log('  ' + l)); } };
say(dryRun ? 'WOULD WRITE' : 'WROTE', wrote);
say('SKIPPED (not collected)', skipped);
say('REFUSED', refused);
say('FAILED TO PARSE', failed);
console.log(`\n${wrote.length} written, ${skipped.length} skipped, ${refused.length} refused, ${failed.length} failed.`);
if (dryRun) console.log('(dry run — nothing was written)');
else if (wrote.length) console.log('\nNext: Tools/private-api/compare-releases.py');
