import { PrivateApiMode } from ".";
import { MacForgeMode } from "./MacForgeMode";
import { MessagesDylibPlugin } from "./dylibPlugins/MessagesDylibPlugin";
import { FaceTimeDylibPlugin } from "./dylibPlugins/FaceTimeDylibPlugin";
import { getLogger } from "@server/lib/logging/Loggable";

export class ProcessDylibMode extends PrivateApiMode {
    static plugins = [new MessagesDylibPlugin("Messages Helper"), new FaceTimeDylibPlugin("FaceTime Helper")];

    static async install() {
        const log = getLogger("ProcessDylibMode");
        for (const plugin of ProcessDylibMode.plugins) {
            try {
                plugin.locateDependencies();
            } catch (e: any) {
                log.warn(`Failed to locate dependencies for ${plugin.name}: ${e?.message ?? String(e)}`);
            }
        }

        await MacForgeMode.uninstall();
    }

    static async uninstall() {
        // Do nothing here
    }

    async start() {
        this.isStopping = false;

        // Start the dylib process
        for (const plugin of ProcessDylibMode.plugins) {
            try {
                // Don't await this. This is a blocking call.
                plugin.injectPlugin();
            } catch (e: any) {
                this.log.warn(`Failed to inject ${plugin.name} DYLIB: ${e?.message ?? String(e)}`);
            }
        }
    }

    async stop() {
        this.isStopping = true;

        // Stop the dylib processes
        for (const plugin of ProcessDylibMode.plugins) {
            try {
                await plugin.stop();
            } catch (ex) {
                this.log.debug(`Error stopping DYLIB for ${plugin.parentApp}! Error: ${ex}`);
            }
        }

        this.isStopping = false;
    }
}
