import path from "path";

/**
 * Parses the "companion DYLIBs" setting: one absolute path per line.
 *
 * Companion DYLIBs are extra helpers that get injected into a plugin's parent app alongside the
 * plugin's own DYLIB. Only one DYLD_INSERT_LIBRARIES value can be set when an app is launched, so any
 * other tool that needs to hook the same app has to be listed here.
 *
 * Anything that can't safely be part of a DYLD_INSERT_LIBRARIES list is skipped with a warning instead
 * of failing. A bad entry must never keep the plugin's own helper from loading.
 *
 * @param raw The raw config value
 * @param ownDylibPath The plugin's own DYLIB, which is always injected and so is never listed twice
 * @param exists Checks whether a file exists (injected so this stays free of file system access)
 * @param warn Reports a skipped entry
 */
export const parseCompanionDylibs = (
    raw: unknown,
    ownDylibPath: string,
    exists: (filePath: string) => boolean,
    warn: (message: string) => void
): string[] => {
    const result: string[] = [];

    for (const line of String(raw ?? "").split("\n")) {
        const entry = line.trim();
        if (!entry || entry === ownDylibPath || result.includes(entry)) continue;

        // ":" separates the entries of DYLD_INSERT_LIBRARIES, so a path containing one can't be passed through
        if (entry.includes(":")) {
            warn(`Ignoring companion DYLIB, ":" is not allowed in the path: ${entry}`);
            continue;
        }

        if (!path.isAbsolute(entry)) {
            warn(`Ignoring companion DYLIB, the path must be absolute: ${entry}`);
            continue;
        }

        if (!exists(entry)) {
            warn(`Ignoring companion DYLIB, the file does not exist: ${entry}`);
            continue;
        }

        result.push(entry);
    }

    return result;
};
