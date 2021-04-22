import Logger from "electron-log";

import { Server, BlueBubblesServer } from "@server/index";
import { LoggerMixin, LogType, NewLog } from "@server/logger";

let instance: ServerLogger = null;
export const ServerLoggerFactory = (server?: BlueBubblesServer): ServerLogger => {
    if (!instance && server) {
        instance = new ServerLogger(server);
    } else if (!instance) {
        return null;
    }

    return instance;
};

export class ServerLogger extends LoggerMixin {
    private server: BlueBubblesServer;

    logger: typeof Logger;

    // eslint-disable-next-line class-methods-use-this
    get logPath(): string {
        return `${Server().appPath}/logs/server.log`;
    }

    constructor(server: BlueBubblesServer) {
        super("server");
        this.server = server;

        // Create the plugin logger
        this.logger = Logger.create(`server`);

        const logFormat = "[{y}-{m}-{d} {h}:{i}:{s}.{ms}] [{level}] {text}";
        this.logger.transports.console.format = logFormat;
        this.logger.transports.file.format = logFormat;
        this.logger.transports.file.resolvePath = () => this.logPath;
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

        if ([LogType.ERROR, LogType.WARN].includes(logType)) {
            // app.setBadgeCount(this.notificationCount);
        }

        return { type: logType, message } as NewLog;
    }
}
