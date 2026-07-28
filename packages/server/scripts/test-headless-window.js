const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const typescript = require("typescript");

const sourcePath = path.resolve(__dirname, "../src/server/utils/WindowUtils.ts");
const sourceCode = fs.readFileSync(sourcePath, "utf8");
const compiledCode = typescript.transpileModule(sourceCode, {
    compilerOptions: {
        module: typescript.ModuleKind.CommonJS,
        target: typescript.ScriptTarget.ES2020
    },
    fileName: sourcePath
}).outputText;

const loadedModule = { exports: {} };
const executeModule = new Function("require", "module", "exports", compiledCode);
executeModule(require, loadedModule, loadedModule.exports);

const { minimizeWindowIfRequested } = loadedModule.exports;
let minimizeCalls = 0;
const window = {
    minimize: () => {
        minimizeCalls += 1;
    }
};

let didMinimize;
assert.doesNotThrow(() => {
    didMinimize = minimizeWindowIfRequested(true, null);
}, "headless startup must not minimize a missing BrowserWindow");
assert.equal(didMinimize, false, "headless startup must report that no window was minimized");
assert.equal(minimizeCalls, 0);

didMinimize = minimizeWindowIfRequested(false, window);
assert.equal(didMinimize, false, "disabled start minimized must report that no window was minimized");
assert.equal(minimizeCalls, 0, "a visible window must remain unchanged when start minimized is disabled");

didMinimize = minimizeWindowIfRequested(true, window);
assert.equal(didMinimize, true, "enabled start minimized must report a successful minimization");
assert.equal(minimizeCalls, 1, "a visible window must still minimize when start minimized is enabled");

console.log("Headless window minimization checks passed.");
