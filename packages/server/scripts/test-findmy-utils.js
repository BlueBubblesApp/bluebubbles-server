const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const ts = require("typescript");

const sourcePath = path.resolve(__dirname, "../src/server/api/lib/findmy/utils.ts");
const source = fs.readFileSync(sourcePath, "utf8");
const compiled = ts.transpileModule(source, {
    compilerOptions: {
        module: ts.ModuleKind.CommonJS,
        target: ts.ScriptTarget.ES2020
    },
    fileName: sourcePath
}).outputText;

const moduleRecord = { exports: {} };
const executeModule = new Function("require", "module", "exports", compiled);
executeModule(require, moduleRecord, moduleRecord.exports);

const { normalizeFindMyLocationItem, normalizeFindMyLocationItems } = moduleRecord.exports;

const normalized = normalizeFindMyLocationItem({
    handle: " alice@example.com ",
    coordinates: ["47.61", "-122.33"],
    long_address: " Seattle, WA ",
    short_address: null,
    subtitle: "",
    title: [42, "", " Alice "],
    last_updated: "1234567",
    is_locating_in_progress: true,
    status: "live"
});

assert.equal(normalized.handle, "alice@example.com");
assert.deepEqual(normalized.coordinates, [47.61, -122.33]);
assert.equal(normalized.long_address, "Seattle, WA");
assert.equal(normalized.short_address, null);
assert.equal(normalized.subtitle, null);
assert.equal(normalized.title, "Alice");
assert.equal(normalized.last_updated, 1234567);
assert.equal(normalized.is_locating_in_progress, 1);
assert.equal(normalized.status, "live");

const missingLocation = normalizeFindMyLocationItem({
    handle: "bob@example.com",
    coordinates: [null, ""],
    long_address: null,
    short_address: null,
    subtitle: null,
    title: null,
    last_updated: "",
    is_locating_in_progress: 0,
    status: "unexpected"
});

assert.equal(missingLocation.coordinates, null, "null/blank coordinates must not become (0, 0)");
assert.equal(missingLocation.last_updated, null);
assert.equal(missingLocation.status, "legacy");

const filtered = normalizeFindMyLocationItems([normalized, { ...missingLocation, handle: null }, missingLocation]);
assert.deepEqual(
    filtered.map(item => item.handle),
    ["alice@example.com", "bob@example.com"]
);
assert.deepEqual(normalizeFindMyLocationItems(null), []);

console.log("PASS: Find My location normalization");
