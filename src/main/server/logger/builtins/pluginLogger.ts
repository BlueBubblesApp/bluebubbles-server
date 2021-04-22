import Logger from "electron-log";

import { Server } from "@server/index";
import { LoggerMixin, LogType, NewLog } from "@server/logger";
import { ServerLoggerFactory } from "@server/logger/builtins/serverLogger";

export class PluginLogger extends LoggerMixin {
    logger: typeof Logger;

    constructor(name: string) {
        super(name);

        // Create the plugin logger
        this.logger = Logger.create(`plugin-${name}`);

        // Turn off console logging because it'll go through the console of the server logger
        this.logger.transports.console.level = false;
        this.logger.transports.file.format = "[{y}-{m}-{d} {h}:{i}:{s}.{ms}] [{level}] {text}";
        this.logger.transports.file.resolvePath = () => this.getLogPath(name);
    }

    getLogPath(name?: string): string {
        const pluginName = name ?? this.name;
        return `${Server().appPath}/logs/plugins/${pluginName}.log`;
    }

    /**
     * Handler for sending logs. This allows us to also route
     * the logs to the main Electron window
     *
     * @param message The message to print
     * @param type The log type
     */
    // eslint-disable-next-line class-methods-use-this
    log(message: any, type?: LogType): NewLog {
        // Forward the log through the global logger
        const logger = ServerLoggerFactory();
        if (logger) logger.log(message, type);

        // Handle our logging needs
        const logType = type ?? LogType.INFO;
        switch (logType) {
            case LogType.ERROR:
                this.logger.error(message);
                break;
            case LogType.DEBUG:
                this.logger.debug(message);
                break;
            case LogType.WARN:
                this.logger.warn(message);
                break;
            case LogType.INFO:
            default:
                this.logger.log(message);
        }

        return { type: logType, message } as NewLog;
    }
}
