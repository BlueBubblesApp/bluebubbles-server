import * as dns from "dns";
import { EventEmitter } from "events";

export class NetworkCheckerService extends EventEmitter {
    online = true;

    isStopped = false;

    async start() {
        // Let's get the initial network connection
        this.online = await NetworkCheckerService.checkNetwork();

        const serviceLoop = async () => {
            if (this.isStopped) return;

            // Check the network connection
            const online = await NetworkCheckerService.checkNetwork();
            if (!this.online && online) {
                this.emit("status-change", true);
            } else if (this.online && !online) {
                this.emit("status-change", false);
            }

            this.online = online;

            // Keep going every 60 seconds!
            setTimeout(serviceLoop, 60000);
        };

        // Initial loop start
        setTimeout(serviceLoop, 0);
    }

    static async checkNetwork(): Promise<boolean> {
        return new Promise((resolve, reject) => {
            dns.resolve("www.google.com", err => {
                if (err) {
                    resolve(false);
                } else {
                    resolve(true);
                }
            });
        });
    }

    stop() {
        this.isStopped = true;
    }
}
