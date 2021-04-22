import * as process from "process";
import { spawn, ChildProcessWithoutNullStreams } from "child_process";

import { IPluginConfig, IPluginTypes, PluginConstructorParams } from "@server/plugins/types";
import { GeneralPluginBase } from "../base";

const configuration: IPluginConfig = {
    name: "caffeinate",
    type: IPluginTypes.GENERAL,
    displayName: "Caffeinate (Keep Awake)",
    description: "Enabling this plugin will keep your Mac awake (except when closing laptop lid)",
    version: 1,
    properties: [],
    dependencies: [] // Other plugins this depends on (<type>.<name>)
};

export default class CaffeinatePlugin extends GeneralPluginBase {
    isCaffeinated = false;

    childProc: ChildProcessWithoutNullStreams;

    constructor(args: PluginConstructorParams) {
        super({ ...args, config: configuration });
    }

    async startup() {
        if (this.isCaffeinated) return;
        const myPid = process.pid;

        // Spawn the child process
        // -i: Create an assertion to prevent the system from idle sleeping.
        // -m: Create an assertion to prevent the disk from idle sleeping.
        // -s: Create an assertion to prevent the system from sleeping
        // -w: Waits for the process with the specified pid to exit.
        this.childProc = spawn("caffeinate", ["-i", "-m", "-s", "-w", myPid.toString()], { detached: true });
        this.logger.info(`Spawned Caffeinate with PID: ${this.childProc.pid}`);
        this.isCaffeinated = true;

        // Setup listeners
        this.childProc.on("close", this.onClose);
        this.childProc.on("exit", this.onClose);
        this.childProc.on("disconnect", this.onClose);
        this.childProc.on("error", this.onClose);
    }

    async shutdown() {
        if (!this.isCaffeinated) return;
        if (this.childProc && this.childProc.pid) {
            // Kill the process
            try {
                const killed = this.childProc.kill();
                if (!killed) process.kill(-this.childProc.pid);
                this.logger.info("Killed caffeinate process");
            } catch (ex) {
                console.error(ex);
                this.logger.error(`Failed to kill caffeinate process! ${ex.message}`);
            } finally {
                this.isCaffeinated = false;
            }
        }
    }

    /**
     * Method to let us know that the caffeinate process has ended
     *
     * @param _ The message returned by the EventEmitter
     */
    private onClose(msg: any) {
        this.isCaffeinated = false;
    }
}
