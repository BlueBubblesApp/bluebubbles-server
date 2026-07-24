import { PrivateApiMode } from ".";
import { MacForgeMode } from "./MacForgeMode";
import { MessagesDylibPlugin } from "./dylibPlugins/MessagesDylibPlugin";
import { FaceTimeDylibPlugin } from "./dylibPlugins/FaceTimeDylibPlugin";
import { FindMyDylibPlugin } from "./dylibPlugins/FindMyDylibPlugin";
import { getLogger } from "@server/lib/logging/Loggable";

export class ProcessDylibMode extends PrivateApiMode {
    static plugins = [
        new MessagesDylibPlugin("Messages Helper"),
        new FaceTimeDylibPlugin("FaceTime Helper"),
        new FindMyDylibPlugin("Find My Helper")
    ];

    static async install() {
        const log = getLogger("ProcessDylibMode");
        for (const plugin of ProcessDylibMode.plugins) {
            try {
                plugin.locateDependencies();
            } catch (error: any) {
                log.warn(`Failed to locate dependencies for ${plugin.name}: ${error?.message ?? String(error)}`);
            }
        }

        await MacForgeMode.uninstall();
    }

    static async uninstall() {
        return;
    }

    async start() {
        this.isStopping = false;

        for (const plugin of ProcessDylibMode.plugins) {
            void plugin.injectPlugin().catch((error: any) => {
                this.log.warn(`Failed to inject ${plugin.name} DYLIB: ${error?.message ?? String(error)}`);
            });
        }
    }

    async stop() {
        this.isStopping = true;

        for (const plugin of ProcessDylibMode.plugins) {
            try {
                await plugin.stop();
            } catch (error) {
                this.log.debug(`Error stopping DYLIB for ${plugin.parentApp}! Error: ${error}`);
            }
        }

        this.isStopping = false;
    }
}
