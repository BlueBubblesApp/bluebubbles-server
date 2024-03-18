import EventEmitter from "events";
import fs from "fs";

export type FileStat = fs.Stats | null | undefined;

export type FileChangeHandlerCallback = (event: FileChangeEvent) => Promise<void>;

export type FileChangeEvent = {
    currentStat: FileStat;
    prevStat: FileStat;
    filePath: string;
};

export class MultiFileWatcher extends EventEmitter {
    tag = "MultiFileWatcher";

    private readonly filePaths: string[];

    private watchers: fs.FSWatcher[] = [];

    private previousStats: Record<string, FileStat> = {};

    constructor(filePaths: string[]) {
        super();
        this.filePaths = filePaths;
    }

    start() {
        for (const filePath of this.filePaths) {
            this.watchFile(filePath);
        }
    }

    private watchFile(filePath: string) {
        // Load the initial stats if the file exists
        if (fs.existsSync(filePath)) {
            this.previousStats[filePath] = fs.statSync(filePath);
        }

        const watcher = fs.watch(filePath, { encoding: "utf8", persistent: false, recursive: false });
        watcher.on("change", async (eventType, _) => {
            if (eventType !== "change") return;

            const currentStat = await fs.promises.stat(filePath);
            this.emit("change", {
                filePath,
                prevStat: { ...this.previousStats[filePath] },
                currentStat: { ...currentStat }
            });

            this.previousStats[filePath] = currentStat;
        });

        watcher.on("error", error => {
            this.emit("error", error);
        });

        this.watchers.push(watcher);
    }

    stop() {
        for (const watcher of this.watchers) {
            watcher.close();
        }
    }
}
