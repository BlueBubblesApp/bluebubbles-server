const assert = require("node:assert/strict");
const babel = require("@babel/core");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const loadTypeScriptModule = sourcePath => {
    const transformed = babel.transformFileSync(sourcePath, {
        presets: [
            [require.resolve("@babel/preset-env"), { targets: { node: "20" }, modules: "commonjs" }],
            require.resolve("@babel/preset-typescript")
        ]
    });
    const loadedModule = { exports: {} };
    const loadModule = new Function("module", "exports", "require", transformed.code);
    loadModule(loadedModule, loadedModule.exports, require);
    return loadedModule.exports;
};

const imageConversionPath = path.join(
    __dirname,
    "..",
    "src",
    "server",
    "databases",
    "imessage",
    "helpers",
    "imageConversion.ts"
);
const { getConvertedImageName, getImageConversion } = loadTypeScriptModule(imageConversionPath);
const sipsConversionPath = path.join(__dirname, "../src/server/fileSystem/sipsImageConversion.ts");
const { convertImageWithSips } = loadTypeScriptModule(sipsConversionPath);

test("converts HEIC and HEIF attachments to PNG", () => {
    assert.deepEqual(getImageConversion("public.heic", "image/heic"), {
        sourceExtension: "heic",
        outputExtension: "png",
        outputMimeType: "image/png"
    });
    assert.deepEqual(getImageConversion("public.heif", "image/heif-sequence"), {
        sourceExtension: "heif",
        outputExtension: "png",
        outputMimeType: "image/png"
    });
});

test("keeps TIFF attachments on the JPEG conversion path", () => {
    assert.deepEqual(getImageConversion("public.tiff", "image/tiff"), {
        sourceExtension: "tiff",
        outputExtension: "jpeg",
        outputMimeType: "image/jpeg"
    });
    assert.deepEqual(getImageConversion(null, "image/tif"), {
        sourceExtension: "tiff",
        outputExtension: "jpeg",
        outputMimeType: "image/jpeg"
    });
});

test("ignores image types that do not require conversion", () => {
    assert.equal(getImageConversion("public.png", "image/png"), null);
});

test("replaces source extensions without duplicating the output extension", () => {
    const conversion = getImageConversion("public.heic", "image/heic");

    assert.equal(getConvertedImageName("photo.HEIC", conversion), "photo.png");
    assert.equal(getConvertedImageName("photo", conversion), "photo.png");
    assert.equal(getConvertedImageName("photo.png", conversion), "photo.png");
});

test(
    "macOS sips converts the transparent HEIC fixture to an alpha-preserving PNG",
    { skip: process.platform !== "darwin" },
    async () => {
        const fixturePath = path.join(__dirname, "fixtures/transparent-alpha.heic");
        const outputDir = fs.mkdtempSync(path.join(os.tmpdir(), "bluebubbles-image-conversion-"));
        const outputPath = path.join(outputDir, "converted.png");
        const executeCommand = command =>
            new Promise((resolve, reject) => {
                childProcess.exec(command, (error, stdout, stderr) => {
                    if (error) {
                        reject(error);
                        return;
                    }
                    resolve(stdout || stderr);
                });
            });

        try {
            await convertImageWithSips(executeCommand, fixturePath, outputPath, "png");

            const metadata = childProcess.execFileSync(
                "/usr/bin/sips",
                ["-g", "format", "-g", "hasAlpha", outputPath],
                { encoding: "utf8" }
            );
            assert.match(metadata, /format: png/);
            assert.match(metadata, /hasAlpha: yes/);
        } finally {
            fs.rmSync(outputDir, { recursive: true, force: true });
        }
    }
);
