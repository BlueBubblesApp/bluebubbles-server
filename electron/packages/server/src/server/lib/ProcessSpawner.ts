import { ChildProcess, SpawnOptionsWithoutStdio, spawn } from "child_process";
import { Loggable } from "./logging/Loggable";


export type ProcessSpawnerConstructorArgs = {
    command: string;
    args?: string[];
    options?: SpawnOptionsWithoutStdio;
    verbose?: boolean;
    onOutput?: ((data: any) => void) | null;
    onExit?: ((code: number) => void) | null;
    logTag?: string | null;
    restartOnNonZeroExit?: boolean;
    restartOnNonZeroExitCondition?: ((code: number) => boolean) | null;
    storeOutput?: boolean;
    waitForExit?: boolean;
    errorOnStderr?: boolean;
};

export type ProcessSpawnerError = {
    message: string;
    output: string;
    process: ChildProcess;
    wasForceQuit: boolean;
};

type ProcessSpawnerOutput = {
    type: "stdout" | "stderr";
    data: string;
};


export class ProcessSpawner extends Loggable {
    tag = "ProcessSpawner";

    command: string;

    args: string[];

    options: SpawnOptionsWithoutStdio;

    verbose: boolean;

    process: ChildProcess;

    restartOnNonZeroExit: boolean;

    restartOnNonZeroExitCondition: ((code: number) => boolean) | null;

    storeOutput: boolean;

    waitForExit: boolean;
    
    errorOnStderr: boolean;

    onOutput: ((data: any) => void) | null;

    onExit: ((code: number) => void) | null;

    private _output: ProcessSpawnerOutput[] = [];

    get output() {
        // Consecutive log outputs of the same type should be appended to the same line.
        // If the type changes, we should add a newline.
        let result = "";
        let prevType = null;
        for (const item of this._output) {
            if (prevType !== null && prevType != item.type) {
                result += `\n${item.data}`;
                prevType = item.type;
                continue;
            }

            result += item.data;
            prevType = item.type;
        }

        return result.trim();
    }

    get stdout() {
        return this._output.filter(x => x.type === "stdout").map(x => x.data).join("").trim();
    }

    get stderr() {
        return this._output.filter(x => x.type === "stderr").map(x => x.data).join("").trim();
    }

    constructor({
        command,
        args = [],
        options = {},
        verbose = false,
        onOutput = null,
        onExit = null,
        logTag = null,
        restartOnNonZeroExit = false,
        restartOnNonZeroExitCondition = null,
        storeOutput = true,
        waitForExit = true,
        errorOnStderr = false
    }: ProcessSpawnerConstructorArgs) {
        super();
        
        this.command = command;
        if (this.command.includes(" ")) {
            this.command = `"${this.command}"`;
        }

        this.args = args;
        this.options = options;
        this.verbose = verbose;
        this.onOutput = onOutput;
        this.onExit = onExit;
        this.restartOnNonZeroExit = restartOnNonZeroExit;
        this.restartOnNonZeroExitCondition = restartOnNonZeroExitCondition;
        this.storeOutput = storeOutput;
        this.waitForExit = waitForExit;
        this.errorOnStderr = errorOnStderr;

        if (logTag) {
            this.tag = logTag;
        }

        if (this.restartOnNonZeroExit && this.waitForExit) {
            throw new Error("Cannot use 'restartOnNonZeroExit' and 'waitForExit' together!");
        }
    }

    async execute(): Promise<ProcessSpawner> {
        return new Promise((resolve: (spawner: ProcessSpawner) => void, reject: (err: ProcessSpawnerError) => void) => {
            try {
                this.process = spawn(this.command, this.quoteArgs(this.args), { ...this.options, shell: true });
                this.process.stdout.on("data", chunk => this.handleOutput(chunk, "stdout"));
                this.process.stderr.on("data", chunk => {
                    this.handleOutput(chunk, "stderr");

                    if (this.errorOnStderr) {
                        reject({
                            message: chunk.toString(),
                            output: this.output,
                            process: this.process,
                            wasForceQuit: false
                        });
                    }
                });
                this.process.on("exit", (code) => {
                    let msg = `Process was force quit`;
                    let wasForceQuit = true;
                    if (code != null) {
                        msg = `Process exited with code: ${code}`;
                        wasForceQuit = false;
                    }

                    this.handleLog(msg);
                    this.handleExit(code);

                    if (this.waitForExit) {
                        if (!this.restartOnNonZeroExit && code !== 0) {
                            reject({
                                message: msg,
                                output: this.output,
                                process: this.process,
                                wasForceQuit
                            });
                        } else {
                            resolve(this);
                        }
                    }
                });

                if (!this.waitForExit) {
                    resolve(this);
                }
            } catch (ex: any) {
                reject({
                    message: ex?.message ?? String(ex),
                    output: this.output,
                    process: this.process,
                    wasForceQuit: false
                });
            }
        });
    }

    private handleLog(log: string) {
        if (this.verbose) {
            this.log.debug(log);
        }
    }

    async handleOutput(chunk: any, type: "stdout" | "stderr") {
        const chunkStr = chunk.toString();
        this.handleLog(`[${type}] ${chunkStr}`);

        if (this.storeOutput) {
            this._output.push({ type, data: chunkStr });
        }
        
        if (this.onOutput) {
            this.onOutput(chunkStr);
        }
    }

    async handleExit(code: number) {
        if (this.onExit) {
            this.onExit(code);
        }

        if (code !== 0 && this.restartOnNonZeroExit) {
            if (!this.restartOnNonZeroExitCondition || this.restartOnNonZeroExitCondition(code)) {
                this.execute();
            }
        }
    }

    async kill() {
        if (this.process) {
            this.process.kill();
        }
    }

    private quoteArgs(args: string[]): string[] {
        return args.map(arg => {
            if (arg.includes(" ")) {
                return `"${arg.replace(/"/g, '\\"')}"`;
            } else {
                return arg;
            }
        });
    }

    static async executeCommand(
        command: string,
        args: string[] = [],
        options: SpawnOptionsWithoutStdio = {},
        tag = 'CommandExecutor',
        verbose = false
    ): Promise<string> {
        const spawner = new ProcessSpawner({
            command,
            args,
            logTag: tag,
            options,
            verbose,
            restartOnNonZeroExit: false,
            storeOutput: true,
            waitForExit: true
        });

        await spawner.execute();
        return spawner.output;
    }
}