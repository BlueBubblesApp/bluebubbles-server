import { Server } from "@server";
import { EventCache } from "@server/eventCache";
import { Message } from "@server/databases/imessage/entity/Message";
import { ScheduledService } from "@server/lib/ScheduledService";
import { Loggable } from "@server/lib/logging/Loggable";

const HEALTH_INTERVAL_MS = 1000 * 5;
const BACKFILL_INTERVAL_MS = 1000 * 60;
const HELPER_HEALTH_INTERVAL_MS = 1000 * 30;
const HELPER_KEEPALIVE_IDLE_MS = 1000 * 30;
const HEARTBEAT_LOOKBACK_MS = 1000 * 60 * 2;
const BACKFILL_LOOKBACK_MS = 1000 * 60 * 10;
const MAX_POLL_TIME_MS = 1000 * 60 * 2;
const HELPER_RECONNECT_GRACE_MS = 1000 * 60 * 2;

export class MessageListenerHealthService extends Loggable {
    tag = "MessageListenerHealthService";

    service: ScheduledService;

    incomingDispatchCache = new EventCache();

    running = false;

    startedAt = 0;

    lastBackfillAt = 0;

    lastHelperHealthAt = 0;

    helperRestarting = false;

    listenerRestarting = false;

    recoveryRunning = false;

    privateApiEventsBound = false;

    private readonly privateApiClientDisconnected = (event: { process?: string }) => {
        this.handlePrivateApiClientDisconnected(event?.process ?? "unknown")
            .catch(ex => this.log.error(`Private API disconnect recovery failed: ${ex?.message ?? ex}`));
    };

    private readonly privateApiClientRegistered = (event: { process?: string }) => {
        this.handlePrivateApiClientRegistered(event?.process ?? "unknown")
            .catch(ex => this.log.error(`Private API reconnect recovery failed: ${ex?.message ?? ex}`));
    };

    start() {
        if (this.service) return;

        this.startedAt = Date.now();
        this.running = false;
        this.bindPrivateApiEvents();
        this.service = new ScheduledService(() => {
            this.run().catch(ex => this.log.error(`Message listener health check failed: ${ex?.message ?? ex}`));
        }, HEALTH_INTERVAL_MS);
        this.run().catch(ex => this.log.error(`Initial message listener health check failed: ${ex?.message ?? ex}`));
    }

    stop() {
        this.service?.stop();
        this.service = null;
        this.unbindPrivateApiEvents();
    }

    recordIncomingMessage(message: Message) {
        if (message?.guid && !message.isFromMe) {
            this.incomingDispatchCache.add(message.guid);
        }
    }

    async handlePrivateApiClientDisconnected(process = "unknown") {
        this.log.warn(`Private API helper disconnected (${process}); running immediate message recovery sweep`);
        await this.runRecoverySweep(`private-api-disconnected-${process}`);
    }

    async handlePrivateApiClientRegistered(process = "unknown") {
        this.log.info(`Private API helper connected (${process}); running reconnect message recovery sweep`);
        await this.runRecoverySweep(`private-api-connected-${process}`);
    }

    private async run() {
        if (this.running) return;
        this.bindPrivateApiEvents();
        this.running = true;

        try {
            await this.ensureMessageListenerHealthy();
            if (this.shouldRunBackfill()) {
                await this.backfillRecentIncomingMessages();
            }
            if (this.shouldCheckPrivateApiHelper()) {
                await this.ensurePrivateApiHelperHealthy();
            }
            this.incomingDispatchCache.trim(BACKFILL_LOOKBACK_MS * 2);
        } finally {
            this.running = false;
        }
    }

    private bindPrivateApiEvents() {
        const privateApi = Server().privateApi;
        if (!privateApi || this.privateApiEventsBound) return;

        privateApi.on("client-disconnected", this.privateApiClientDisconnected);
        privateApi.on("client-registered", this.privateApiClientRegistered);
        this.privateApiEventsBound = true;
    }

    private unbindPrivateApiEvents() {
        const privateApi = Server().privateApi;
        if (!privateApi || !this.privateApiEventsBound) return;

        privateApi.off("client-disconnected", this.privateApiClientDisconnected);
        privateApi.off("client-registered", this.privateApiClientRegistered);
        this.privateApiEventsBound = false;
    }

    private async runRecoverySweep(reason: string) {
        if (this.recoveryRunning) return;
        this.recoveryRunning = true;

        try {
            this.log.info(`Running message recovery sweep (${reason})`);
            await this.ensureMessageListenerHealthy();
            await this.backfillRecentIncomingMessages();
        } finally {
            this.recoveryRunning = false;
        }
    }

    private shouldRunBackfill() {
        const now = Date.now();
        if (now - this.lastBackfillAt < BACKFILL_INTERVAL_MS) return false;

        this.lastBackfillAt = now;
        return true;
    }

    private shouldCheckPrivateApiHelper() {
        const now = Date.now();
        if (now - this.lastHelperHealthAt < HELPER_HEALTH_INTERVAL_MS) return false;

        this.lastHelperHealthAt = now;
        return true;
    }

    private async ensureMessageListenerHealthy() {
        const server = Server();
        const listener = server.iMessageListener;
        if (!server.hasDiskAccess || !server.iMessageRepo) return;

        if (!listener) {
            await this.restartMessageListener("message-listener-missing");
            return;
        }

        const heartbeat = listener.getHeartbeat();
        const now = Date.now();
        const pollAge = now - heartbeat.lastPollStartedAt;

        if (heartbeat.stopped || !heartbeat.watcherActive) {
            await this.restartMessageListener("message-listener-stopped");
            return;
        }

        if (heartbeat.pollInFlight && pollAge > MAX_POLL_TIME_MS) {
            await this.restartMessageListener(`message-listener-poll-stuck-${pollAge}ms`);
            return;
        }

        await listener.heartbeat(new Date(now - HEARTBEAT_LOOKBACK_MS));
    }

    private async restartMessageListener(reason: string) {
        if (this.listenerRestarting) return;

        this.listenerRestarting = true;
        try {
            await Server().restartChatListenersOnly(reason);
        } finally {
            this.listenerRestarting = false;
        }
    }

    private async backfillRecentIncomingMessages() {
        const server = Server();
        if (!server.hasDiskAccess || !server.iMessageRepo) return;

        const after = new Date(Date.now() - BACKFILL_LOOKBACK_MS);
        const [messages] = await server.iMessageRepo.getMessages({
            after,
            limit: 100,
            withChats: true,
            withAttachments: true,
            sort: "ASC",
            orderBy: "message.dateCreated",
            where: [
                {
                    statement: "message.is_from_me = 0",
                    args: null
                }
            ]
        });

        for (const message of messages) {
            if (!message.guid || message.isFromMe) continue;
            if ((message.dateCreated?.getTime() ?? 0) < after.getTime()) continue;
            if (this.incomingDispatchCache.find(message.guid)) continue;

            this.log.warn(`Backfilling missed incoming message dispatch: ${message.guid}`);
            await server.dispatchBackfilledIncomingMessage(message);
        }
    }

    private async ensurePrivateApiHelperHealthy() {
        const server = Server();
        const privateApiEnabled = server.repo?.getConfig("enable_private_api") as boolean;
        const ftPrivateApiEnabled = server.repo?.getConfig("enable_ft_private_api") as boolean;
        if (!privateApiEnabled && !ftPrivateApiEnabled) return;
        if (!server.privateApi || this.helperRestarting) return;

        const health = server.privateApi.getHealthSnapshot();
        if (health.clients > 0) {
            await this.keepPrivateApiHelperWarm(health);
            return;
        }
        if (Date.now() - health.startedAt < HELPER_RECONNECT_GRACE_MS) return;

        this.helperRestarting = true;
        try {
            this.log.warn("Private API helper has no connected clients; restarting helper listener only");
            await server.privateApi.restart();
        } finally {
            this.helperRestarting = false;
        }
    }

    private async keepPrivateApiHelperWarm(health: { lastClientActivityAt: number }) {
        const lastActivityAt = health.lastClientActivityAt || this.startedAt;
        const idleMs = Date.now() - lastActivityAt;
        if (idleMs < HELPER_KEEPALIVE_IDLE_MS) return;

        this.log.debug(`Private API helper idle for ${idleMs}ms; sending keepalive ping`);
        await Server().privateApi.keepAlive();
    }

}
