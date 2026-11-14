const path = require("node:path");
const typescript = require("typescript");

const root = path.resolve(__dirname, "../../..");
const formatHost = {
    getCanonicalFileName: file => file,
    getCurrentDirectory: () => root,
    getNewLine: () => "\n"
};

for (const workspace of ["server", "ui"]) {
    const filename = path.join(root, "packages", workspace, "tsconfig.json");
    const parsed = typescript.getParsedCommandLineOfConfigFile(filename, {}, {
        ...typescript.sys,
        onUnRecoverableConfigFileDiagnostic: diagnostic => {
            throw new Error(typescript.formatDiagnostics([diagnostic], formatHost));
        }
    });
    // Validate options without importing app modules, emitting files, or claiming
    // to replace the production build's source type-checking.
    const program = typescript.createProgram({ rootNames: [], options: parsed.options });
    const errors = [...parsed.errors, ...program.getOptionsDiagnostics()]
        .filter(diagnostic => diagnostic.category === typescript.DiagnosticCategory.Error);
    if (errors.length > 0) {
        throw new Error(typescript.formatDiagnostics(errors, formatHost));
    }
    console.log(`Verified ${workspace} compiler options with TypeScript ${typescript.version}`);
}
