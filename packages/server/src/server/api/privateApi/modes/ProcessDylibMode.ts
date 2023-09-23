import "zx/globals";
import { PrivateApiMode } from ".";
import { MacForgeMode } from "./MacForgeMode";
import { DylibPlugin } from "./dylibPlugins";
import { MessagesDylibPlugin } from "./dylibPlugins/MessagesDylibPlugin";
import { FaceTimeDylibPlugin } from "./dylibPlugins/FaceTimeDylibPlugin";


export class ProcessDylibMode extends PrivateApiMode {

    static plugins: DylibPlugin[] = [
        new MessagesDylibPlugin("Messages Helper"),
        new FaceTimeDylibPlugin("FaceTime Helper")
    ]
    
    static async install() {
        for (const plugin of ProcessDylibMode.plugins) {
            plugin.locateDependencies();
        }

        await MacForgeMode.uninstall();
    }

    static async uninstall() {
        // Nothing to do here
    }

    async start() {
        this.isStopping = false;

        // Start the dylib process
        for (const plugin of ProcessDylibMode.plugins) {
            // Don't await this. This is a blocking call.
            plugin.injectPlugin();
        }
    }

    async stop() {
        this.isStopping = true;

        // Stop the dylib process
        for (const plugin of ProcessDylibMode.plugins) {
            await plugin.stop();
        }

        this.isStopping = false;
    }
}