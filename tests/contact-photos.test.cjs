const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const ts = require("../packages/server/node_modules/typescript");
const source = fs.readFileSync(
  path.join(
    __dirname,
    "../packages/server/src/server/api/interfaces/contactInterface.ts"
  ),
  "utf8"
);
const js = ts.transpileModule(source, {
  compilerOptions: {
    module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2020,
  },
}).outputText;
const deps = {
  "@server": {},
  fs,
  vcf: {},
  "@server/helpers/utils": {
    isEmpty: (v) => v == null || v.length === 0,
    isNotEmpty: (v) => v != null && v.length !== 0,
    deduplicateObjectArray: (a, k) =>
      a.filter((v, i) => a.findIndex((x) => x[k] === v[k]) === i),
  },
  "byte-base64": { bytesToBase64: (b) => Buffer.from(b).toString("base64") },
  "../lib/ContactsLib": {},
};
const mod = { exports: {} };
vm.runInThisContext(`(function(require,module,exports){${js}\n})`)(
  (n) => {
    if (n in deps) return deps[n];
    throw Error("Unexpected dependency " + n);
  },
  mod,
  mod.exports
);
const { ContactInterface } = mod.exports;
test("native Contacts thumbnail survives absent or empty full-size image", () => {
  for (const full of [undefined, null, Buffer.alloc(0)]) {
    for (const prop of ["avatar", "contactImage", "contactThumbnailImage"]) {
      const [c] = ContactInterface.mapContacts(
        [
          {
            firstName: "Example",
            contactImage: full,
            contactThumbnailImage: Buffer.from("thumbnail"),
          },
        ],
        "api",
        { extraProps: [prop] }
      );
      assert.equal(c.avatar, Buffer.from("thumbnail").toString("base64"));
    }
  }
});
test("full-size and imported images retain precedence; no photo stays absent", () => {
  const [full] = ContactInterface.mapContacts(
    [
      {
        contactImage: Buffer.from("full"),
        contactThumbnailImage: Buffer.from("thumbnail"),
      },
    ],
    "api",
    { extraProps: ["contactImage"] }
  );
  assert.equal(full.avatar, Buffer.from("full").toString("base64"));
  const [imported] = ContactInterface.mapContacts(
    [{ avatar: Buffer.from("imported"), contactImage: Buffer.from("full") }],
    "db",
    { extraProps: ["avatar"] }
  );
  assert.equal(imported.avatar, Buffer.from("imported").toString("base64"));
  assert.equal(
    ContactInterface.mapContacts([{}], "api", { extraProps: ["avatar"] })[0]
      .avatar,
    ""
  );
});
