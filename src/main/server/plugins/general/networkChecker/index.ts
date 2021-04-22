import * as dns from "dns";

import { IPluginConfig, IPluginConfigPropItemType, IPluginTypes, PluginConstructorParams } from "@server/plugins/types";
import { GeneralPluginBase } from "../base";

const configuration: IPluginConfig = {
    name: "networkChecker",
    type: IPluginTypes.GENERAL,
    displayName: "Network Checker",
    description: "Enabling this plugin will allow BlueBubbles to detect if you ever go offline.",
    version: 1,
    properties: [
        {
            name: "interval",
            label: "Check Interval",
            type: IPluginConfigPropItemType.NUMBER,
            description: "How often (in seconds) to check for a network connection",
            default: 5,
            required: true
        }
    ],
    dependencies: [] // Other plugins this depends on (<type>.<name>)
};

export default class NetworkCheckerPlugin extends GeneralPluginBase {
    online = true;

    isStopped = false;

    timeoutLoop: NodeJS.Timeout = null;

    constructor(args: PluginConstructorParams) {
        super({ ...args, config: configuration });
    }

    async startup() {
        // Let's get the initial network connection
        this.online = await NetworkCheckerPlugin.checkNetwork();

        const serviceLoop = async () => {
            if (this.isStopped) return;

            // Check the network connection
            const online = await NetworkCheckerPlugin.checkNetwork();
            if (!this.online && online) {
                this.emit("status-change", true);
            } else if (this.online && !online) {
                this.emit("status-change", false);
            }

            this.online = online;

            // Keep going every 5 seconds!
            this.timeoutLoop = setTimeout(serviceLoop, 5000);
        };

        // Initial loop start
        this.timeoutLoop = setTimeout(serviceLoop, 0);
    }

    async shutdown() {
        this.isStopped = true;
        clearTimeout(this.timeoutLoop);
        this.timeoutLoop = null;
    }

    static async checkNetwork(): Promise<boolean> {
        return new Promise((resolve, _) => {
            dns.resolve("www.google.com", err => {
                if (err) {
                    resolve(false);
                } else {
                    resolve(true);
                }
            });
        });
    }
}
