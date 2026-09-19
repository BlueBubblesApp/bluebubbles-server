import { ScheduledService } from "@server/lib/ScheduledService";
import { Loggable } from "@server/lib/logging/Loggable";
import * as dns from "dns";

export class NetworkCheckerService extends Loggable {
    tag = "NetworkCheckerService";

    online = true;

    isStopped = false;

    serviceLoop: ScheduledService;

    async start() {
        // Let's get the initial network connection
        this.online = await NetworkCheckerService.checkNetwork();

        // Start the service loop
        this.serviceLoop = new ScheduledService(() => {
            if (this.isStopped) {
                this.serviceLoop.stop();
                return;
            }

            // Check the network connection
            NetworkCheckerService.checkNetwork().then(online => {
                if (!this.online && online) {
                    this.emit("status-change", true);
                } else if (this.online && !online) {
                    this.emit("status-change", false);
                }

                this.online = online;
            });
        }, 60000);
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
        this.serviceLoop?.stop();
    }
}
