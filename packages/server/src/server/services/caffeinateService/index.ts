import * as process from "process";
import { spawn, ChildProcessWithoutNullStreams } from "child_process";
import { Loggable } from "@server/lib/logging/Loggable";

/**
 * Service that spawns the pmset process so that
 * the macOS operating system does not sleep until the server
 * exits.
 */
export class CaffeinateService extends Loggable {
    tag = "CaffeinateService";

    isCaffeinated = false;

    childProc: ChildProcessWithoutNullStreams;

    originalSleepSettings: { displaysleep: string; disksleep: string; sleep: string } = {
        displaysleep: "",
        disksleep: "",
        sleep: ""
    };

    /**
     * Runs pmset until the current process is killed
     */
    start() {
        if (this.isCaffeinated) return;
        const myPid = process.pid;

        // Cache existing sleep values
        this.cacheSleepValues();

        // Spawn the child process
        // Prevent system sleep
        this.childProc = spawn("pmset", ["-a", "displaysleep", "0", "disksleep", "0", "sleep", "0"], { detached: true });
        this.log.info(`Spawned pmset with PID: ${this.childProc.pid}`);
        this.isCaffeinated = true;

        // Setup listeners
        this.childProc.on("close", this.onClose);
        this.childProc.on("exit", this.onClose);
        this.childProc.on("disconnect", this.onClose);
        this.childProc.on("error", this.onClose);
    }

    /**
     * Stops being caffeinated
     */
    stop() {
        if (!this.isCaffeinated) return;
        if (this.childProc && this.childProc.pid) {
            // Kill the process
            try {
                const killed = this.childProc.kill();
                if (!killed) process.kill(-this.childProc.pid);
                this.log.debug("Killed pmset process");
            } catch (ex: any) {
                this.log.error(`Failed to kill pmset process! ${ex.message}`);
            } finally {
                this.isCaffeinated = false;
                // Restore cached sleep values
                this.restoreSleepValues();
            }
        }
    }

    /**
     * Method to let us know that the pmset process has ended
     *
     * @param _ The message returned by the EventEmitter
     */
    private onClose(msg: any) {
        this.isCaffeinated = false;
    }

    /**
     * Cache the current sleep values
     */
    private cacheSleepValues() {
        const displaysleep = this.executePmsetCommand("displaysleep");
        const disksleep = this.executePmsetCommand("disksleep");
        const sleep = this.executePmsetCommand("sleep");

        this.originalSleepSettings = { displaysleep, disksleep, sleep };
    }

    /**
     * Restore the cached sleep values
     */
    private restoreSleepValues() {
        const { displaysleep, disksleep, sleep } = this.originalSleepSettings;

        this.executePmsetCommand("displaysleep", displaysleep);
        this.executePmsetCommand("disksleep", disksleep);
        this.executePmsetCommand("sleep", sleep);
    }

    /**
     * Execute pmset command
     */
    private executePmsetCommand(setting: string, value?: string): string {
        const args = value ? ["-a", setting, value] : ["-g", setting];
        const result = spawnSync("pmset", args);
        return result.stdout.toString().trim();
    }
}
