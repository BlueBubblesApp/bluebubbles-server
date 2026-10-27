import fs from "fs";
import Module from "module";
import path from "path";
import nodeFetch from "node-fetch";

/**
 * gaxios 7 (used by firebase-admin 13 and googleapis 178) loads its HTTP client with
 * `await import("node-fetch")`. Electron 25's ESM loader can't resolve packages inside app.asar:
 * it stats `<app.asar>/.../node_modules/node-fetch` with the real fs and fails with ENOTDIR, so
 * every Google request (FCM, the OAuth setup) fails in packaged builds while `npm start` works.
 *
 * node-fetch is bundled into main.js instead (see the externals allowlist in webpack.main.config.js)
 * and handed to every gaxios 7+ copy as its default `fetchImplementation`, which gaxios checks before
 * importing node-fetch itself. Remove this once Electron is on 28+, whose ESM loader reads asar.
 *
 * Not covered: with an HTTP(S)_PROXY env var set, gaxios 7 also `import()`s https-proxy-agent.
 */

type GaxiosModule = {
    Gaxios?: {
        prototype: {
            defaults?: { fetchImplementation?: unknown };
            _defaultAdapter?: (config: Record<string, unknown>) => Promise<unknown>;
        };
    };
};

type ModuleInternals = {
    _load: (request: string, parent: unknown, isMain: boolean) => unknown;
    _resolveFilename: (request: string, parent: unknown, isMain: boolean) => string;
};

const seen = new WeakSet<object>();

const gaxiosMajorVersion = (entryFile: string): number => {
    const marker = `${path.sep}node_modules${path.sep}gaxios${path.sep}`;
    const index = entryFile.lastIndexOf(marker);
    if (index === -1) return 0;

    const packageJson = path.join(entryFile.slice(0, index + marker.length), "package.json");
    return Number.parseInt(JSON.parse(fs.readFileSync(packageJson, "utf8")).version, 10);
};

const patchGaxios = (exports: GaxiosModule, entryFile: string) => {
    const proto = exports?.Gaxios?.prototype;
    if (!proto?._defaultAdapter || seen.has(proto)) return;
    seen.add(proto);

    // gaxios 6 and older require node-fetch 2 synchronously and work as they are.
    if (gaxiosMajorVersion(entryFile) < 7) return;

    const defaultAdapter = proto._defaultAdapter;
    proto._defaultAdapter = function (this: typeof proto, config: Record<string, unknown>) {
        if (!config.fetchImplementation && !this.defaults?.fetchImplementation) {
            config = { ...config, fetchImplementation: nodeFetch };
        }

        return defaultAdapter.call(this, config);
    };
};

const moduleInternals = Module as unknown as ModuleInternals;
const load = moduleInternals._load;
moduleInternals._load = function (request: string, parent: unknown, isMain: boolean) {
    const exports = load.call(this, request, parent, isMain);
    if (request === "gaxios") {
        patchGaxios(exports as GaxiosModule, moduleInternals._resolveFilename(request, parent, isMain));
    }

    return exports;
};
