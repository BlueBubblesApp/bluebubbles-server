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
        storeOutput = true,
        waitForExit = true,
        errorOnStderr = false
    }: ProcessSpawnerConstructorArgs) {
        super();
        
        this.command = command;
        this.args = args;
        this.options = options;
        this.verbose = verbose;
        this.onOutput = onOutput;
        this.onExit = onExit;
        this.restartOnNonZeroExit = restartOnNonZeroExit;
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
                this.process = this.spawnProcesses();
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

    private spawnProcesses() {
        // If the args contain a pipe character, we need to split the command and args into separate processes.
        // The separate processes should dynamically pipe the result into the next, returning the last process
        // as the final result.
        if (this.args.some(arg => arg.includes("|"))) {
            // Combine the command and args into a single string
            const commandStr = `${this.command} ${this.args.join(" ")}`;

            // Split by the pipe character, and trim any whitespace
            const commands = commandStr.split("|").map(x => x.trim());
            if (commands.length < 2) {
                throw new Error(`Invalid pipe command! Input: ${commandStr}`);
            }

            // Iterate over the commands, executing them and piping the
            // output to the next process. Then return the last process.
            let lastProcess: ChildProcess = null;
            for (let i = 0; i < commands.length; i++) {
                const command = commands[i].trim();

                // Get the command
                if (!command) {
                    throw new Error(`Invalid command! Input: ${command}`);
                }

                // Pull the first command off the list
                const commandParts = command.split(" ");
                const program = commandParts[0];
                const args = commandParts.slice(1);

                // Spawn the process and pipe the output to the next process
                const proc = spawn(program, args, {
                    stdio: [
                        // If there is a previous process, pipe the output to the next process
                        (lastProcess) ? lastProcess.stdout : "pipe",
                        "pipe",
                        "pipe"
                    ]
                });

                lastProcess = proc;
            }

            return lastProcess;
        }

        return spawn(this.command, this.args, this.options);
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
            this.execute();
        }
    }

    async kill() {
        if (this.process) {
            this.process.kill();
        }
    }

    static async executeCommand(
        command: string,
        args: string[] = [],
        options: SpawnOptionsWithoutStdio = {},
        tag = 'CommandExecutor'
    ): Promise<string> {
        const spawner = new ProcessSpawner({
            command,
            args,
            logTag: tag,
            options,
            verbose: false,
            restartOnNonZeroExit: false,
            storeOutput: true,
            waitForExit: true
        });

        await spawner.execute();
        return spawner.output;
    }
}