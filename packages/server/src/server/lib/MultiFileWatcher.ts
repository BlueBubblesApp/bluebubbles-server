import EventEmitter from "events";
import fs from "fs";
import path from "path";

export type FileStat = fs.Stats | null | undefined;

export type FileChangeHandlerCallback = (event: FileChangeEvent) => Promise<void>;

export type FileChangeEvent = {
    currentStat: FileStat;
    prevStat: FileStat;
    filePath: string;
};

const MAX_CONSECUTIVE_REARMS = 5;

export class MultiFileWatcher extends EventEmitter {
    tag = "MultiFileWatcher";

    private readonly filePaths: string[];

    private watchers: Map<string, fs.FSWatcher> = new Map();

    private rearmAttempts: Map<string, number> = new Map();

    private previousStats: Record<string, FileStat> = {};

    private stopped = true;

    constructor(filePaths: string[]) {
        super();
        this.filePaths = filePaths;
    }

    start() {
        if (!this.stopped) return;
        this.stopped = false;

        for (const filePath of this.filePaths) {
            this.previousStats[filePath] = MultiFileWatcher.statOrNull(filePath);
        }

        for (const dirPath of this.watchedDirectories()) {
            this.watchDirectory(dirPath);
        }
    }

    stop() {
        this.stopped = true;

        for (const watcher of this.watchers.values()) {
            watcher.removeAllListeners();
            watcher.close();
        }

        this.watchers.clear();
        this.rearmAttempts.clear();
    }

    private watchedDirectories(): string[] {
        return Array.from(new Set(this.filePaths.map(filePath => path.dirname(filePath))));
    }

    private watchDirectory(dirPath: string) {
        if (this.stopped || this.watchers.has(dirPath)) return;

        let watcher: fs.FSWatcher;

        try {
            watcher = fs.watch(dirPath, { encoding: "utf8", persistent: false, recursive: false });
        } catch (error) {
            this.emit("error", error);
            this.rearm(dirPath);
            return;
        }

        watcher.on("change", (_eventType, fileName) => {
            this.rearmAttempts.delete(dirPath);

            const affected = this.affectedPaths(dirPath, fileName ? fileName.toString() : null);
            if (affected.length === 0) return;

            this.detectChanges(affected);
        });

        watcher.on("error", error => {
            this.emit("error", error);
            this.rearm(dirPath);
        });

        this.watchers.set(dirPath, watcher);
    }

    private rearm(dirPath: string) {
        if (this.stopped) return;

        const existing = this.watchers.get(dirPath);
        if (existing) {
            existing.removeAllListeners();
            existing.close();
            this.watchers.delete(dirPath);
        }

        const attempts = (this.rearmAttempts.get(dirPath) ?? 0) + 1;
        if (attempts > MAX_CONSECUTIVE_REARMS) {
            this.emit("error", new Error(`Stopped watching ${dirPath} after ${attempts} consecutive failures`));
            return;
        }

        this.rearmAttempts.set(dirPath, attempts);
        this.watchDirectory(dirPath);
    }

    private affectedPaths(dirPath: string, fileName: string | null): string[] {
        const inDirectory = this.filePaths.filter(filePath => path.dirname(filePath) === dirPath);
        if (!fileName) return inDirectory;
        return inDirectory.filter(filePath => fileName.startsWith(path.basename(filePath)));
    }

    private detectChanges(filePaths: string[]) {
        if (this.stopped) return;

        for (const filePath of filePaths) {
            const previousStat = this.previousStats[filePath];
            const currentStat = MultiFileWatcher.statOrNull(filePath);
            if (!MultiFileWatcher.hasChanged(previousStat, currentStat)) continue;

            this.previousStats[filePath] = currentStat;
            this.emit("change", {
                filePath,
                prevStat: previousStat ? { ...previousStat } : previousStat,
                currentStat: currentStat ? { ...currentStat } : currentStat
            });
        }
    }

    private static hasChanged(previousStat: FileStat, currentStat: FileStat): boolean {
        if (!previousStat && !currentStat) return false;
        if (!previousStat || !currentStat) return true;

        return (
            previousStat.mtimeMs !== currentStat.mtimeMs ||
            previousStat.size !== currentStat.size ||
            previousStat.ino !== currentStat.ino
        );
    }

    private static statOrNull(filePath: string): FileStat {
        try {
            return fs.statSync(filePath);
        } catch (error) {
            return null;
        }
    }
}
