import * as process from "process";
import { spawn, ChildProcessWithoutNullStreams } from "child_process";
import { Loggable } from "@server/lib/logging/Loggable";

/**
 * Service that spawns the caffeinate process so that
 * the macOS operating system does not sleep until the server
 * exits.
 */
export class CaffeinateService extends Loggable {
    tag = "CaffeinateService";

    isCaffeinated = false;

    childProc: ChildProcessWithoutNullStreams;

    /**
     * Runs caffeinate until the current process is killed
     */
    start() {
        if (this.isCaffeinated) return;
        const myPid = process.pid;

        // Spawn the child process
        // -i: Create an assertion to prevent the system from idle sleeping.
        // -m: Create an assertion to prevent the disk from idle sleeping.
        // -s: Create an assertion to prevent the system from sleeping
        // -w: Waits for the process with the specified pid to exit.
        this.childProc = spawn("caffeinate", ["-i", "-m", "-s", "-w", myPid.toString()], { detached: true });
        this.log.info(`Spawned Caffeinate with PID: ${this.childProc.pid}`);
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
                this.log.debug("Killed caffeinate process");
            } catch (ex: any) {
                this.log.error(`Failed to kill caffeinate process! ${ex.message}`);
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
