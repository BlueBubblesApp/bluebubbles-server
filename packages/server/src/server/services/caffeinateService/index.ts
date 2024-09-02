import * as process from "process";
import { spawn, ChildProcessWithoutNullStreams } from "child_process";
import { Loggable } from "@server/lib/logging/Loggable";
import { setInterval } from "timers";

/**
 * Service that spawns the caffeinate process so that
 * the macOS operating system does not sleep until the server
 * exits.
 */
export class CaffeinateService extends Loggable {
    tag = "CaffeinateService";

    isCaffeinated = false;
    childProc: ChildProcessWithoutNullStreams;
    watchdogInterval: NodeJS.Timeout;

    /**
     * Runs caffeinate with stricter settings and additional safeguards
     * to ensure the system does not sleep until the current process is killed.
     */
    start() {
        if (this.isCaffeinated) return;
        const myPid = process.pid;

        // Spawn the child process with stricter flags to prevent sleep under all conditions
        // -i: Prevent idle sleep.
        // -m: Prevent disk sleep.
        // -s: Prevent system sleep.
        // -d: Prevent display sleep.
        // -u: Simulate user activity to prevent display sleep.
        // -t 0: Run indefinitely.
        // -w: Wait for the process with the specified pid to exit.
        this.childProc = spawn("caffeinate", ["-i", "-m", "-s", "-d", "-u", "-t", "0", "-w", myPid.toString()], { detached: true });
        this.log.info(`Spawned Caffeinate with PID: ${this.childProc.pid}`);
        this.isCaffeinated = true;

        // Setup listeners for enhanced error handling and recovery
        this.childProc.on("close", (code) => this.onClose(code));
        this.childProc.on("exit", (code) => this.onExit(code));
        this.childProc.on("disconnect", () => this.onDisconnect());
        this.childProc.on("error", (err) => this.onError(err));

        // Watchdog timer to check if the process is still alive
        this.watchdogInterval = setInterval(() => {
            if (this.childProc.killed || !this.childProc.connected) {
                this.log.warn("Caffeinate process appears to have stopped. Restarting...");
                this.start(); // Restart caffeinate if it has stopped
            }
        }, 5000); // Check every 5 seconds

        // Ensure the process is not prematurely terminated
        process.on('SIGTERM', () => this.stop());
        process.on('SIGINT', () => this.stop());
        process.on('uncaughtException', (err) => {
            this.log.error(`Uncaught exception: ${err.message}`);
            this.stop(); // Stop caffeinate if an uncaught exception occurs
            process.exit(1);
        });
    }

    /**
     * Stops the caffeinate process safely
     */
    stop() {
        if (!this.isCaffeinated) return;
        clearInterval(this.watchdogInterval); // Stop the watchdog

        if (this.childProc && this.childProc.pid) {
            // Kill the process
            try {
                const killed = this.childProc.kill();
                if (!killed) process.kill(-this.childProc.pid); // Force kill if needed
                this.log.debug("Killed caffeinate process");
            } catch (ex: any) {
                this.log.error(`Failed to kill caffeinate process! ${ex.message}`);
            } finally {
                this.isCaffeinated = false; // Reset the caffeinated state
            }
        }
    }

    /**
     * Method to let us know that the caffeinate process has ended
     *
     * @param code The exit code or signal that caused the process to exit
     */
    private onClose(code: any) {
        this.log.warn(`Caffeinate process closed with code: ${code}. Restarting...`);
        this.isCaffeinated = false;
        this.start(); // Restart caffeinate to maintain wakefulness
    }

    /**
     * Method to handle when the caffeinate process exits
     *
     * @param code The exit code or signal that caused the process to exit
     */
    private onExit(code: any) {
        this.log.warn(`Caffeinate process exited with code: ${code}. Restarting...`);
        this.isCaffeinated = false;
        this.start(); // Restart caffeinate to maintain wakefulness
    }

    /**
     * Method to handle when the caffeinate process disconnects
     */
    private onDisconnect() {
        this.log.warn("Caffeinate process disconnected. Restarting...");
        this.isCaffeinated = false;
        this.start(); // Restart caffeinate to maintain wakefulness
    }

    /**
     * Method to handle errors in the caffeinate process
     *
     * @param err The error encountered by the child process
     */
    private onError(err: any) {
        this.log.error(`Caffeinate process encountered an error: ${err.message}. Restarting...`);
        this.isCaffeinated = false;
        this.start(); // Restart caffeinate to maintain wakefulness
    }
}
