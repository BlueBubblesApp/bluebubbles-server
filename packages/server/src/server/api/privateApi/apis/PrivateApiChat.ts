import { Server } from "@server";
import {
    TransactionPromise,
    TransactionResult,
    TransactionType
} from "@server/managers/transactionManager/transactionPromise";
import { PrivateApiAction } from ".";
import { v4 as uuidv4 } from "uuid";

export class PrivateApiChat extends PrivateApiAction {
    tag = "PrivateApiChat";

    async create({
        addresses,
        message,
        service = "iMessage",
        attributedBody = null,
        effectId = null,
        subject = null,
        forceNew = false
    }: {
        addresses: string[];
        message?: string | null;
        service?: "iMessage" | "SMS";
        attributedBody?: Record<string, any> | null;
        effectId?: string;
        subject?: string;
        forceNew?: boolean;
    }): Promise<TransactionResult> {
        const action = "create-chat";
        this.throwForNoMissingFields(action, forceNew ? [addresses] : [addresses, message]);
        const creationToken = forceNew ? uuidv4() : null;

        // Silent creation returns the chat GUID directly; creation with a first
        // message retains the existing message-GUID transaction behavior.
        const request = new TransactionPromise(message ? TransactionType.MESSAGE : TransactionType.CHAT);
        return this.sendApiMessage(
            "create-chat",
            {
                addresses,
                message,
                service,
                attributedBody,
                effectId,
                subject,
                forceNew,
                creationToken
            },
            request
        );
    }

    async deleteMessage(chatGuid: string, messageGuid: string): Promise<TransactionResult> {
        const action = "delete-message";
        this.throwForNoMissingFields(action, [chatGuid, messageGuid]);
        const request = new TransactionPromise(TransactionType.CHAT);
        return this.sendApiMessage(action, { chatGuid, messageGuid }, request);
    }

    async startTyping(chatGuid: string): Promise<TransactionResult> {
        const action = "start-typing";
        this.throwForNoMissingFields(action, [chatGuid]);
        return this.sendApiMessage(action, { chatGuid });
    }

    async stopTyping(chatGuid: string): Promise<TransactionResult> {
        const action = "stop-typing";
        this.throwForNoMissingFields(action, [chatGuid]);
        return this.sendApiMessage(action, { chatGuid });
    }

    async markRead(chatGuid: string): Promise<TransactionResult> {
        const action = "mark-chat-read";
        this.throwForNoMissingFields(action, [chatGuid]);
        return this.sendApiMessage(action, { chatGuid });
    }

    async markUnread(chatGuid: string) {
        const action = "mark-chat-unread";
        this.throwForNoMissingFields(action, [chatGuid]);
        return this.sendApiMessage(action, { chatGuid });
    }

    async toggleParticipant(chatGuid: string, address: string, pAction: "add" | "remove"): Promise<TransactionResult> {
        const action = `${pAction}-participant`;
        this.throwForNoMissingFields(action, [chatGuid, address, pAction]);
        const request = new TransactionPromise(TransactionType.CHAT);
        return this.sendApiMessage(action, { chatGuid, address }, request);
    }

    async addParticipant(chatGuid: string, address: string) {
        return this.toggleParticipant(chatGuid, address, "add");
    }

    async removeParticipant(chatGuid: string, address: string) {
        return this.toggleParticipant(chatGuid, address, "remove");
    }

    async setDisplayName(chatGuid: string, newName: string): Promise<TransactionResult> {
        const action = "set-display-name";
        this.throwForNoMissingFields(action, [chatGuid, newName]);
        const request = new TransactionPromise(TransactionType.CHAT);
        return this.sendApiMessage(action, { chatGuid, newName }, request);
    }

    async setGroupChatIcon(chatGuid: string, filePath: string | null): Promise<TransactionResult> {
        const action = "update-group-photo";
        this.throwForNoMissingFields(action, [chatGuid]);
        const request = new TransactionPromise(TransactionType.CHAT);
        return this.sendApiMessage(action, { chatGuid, filePath }, request);
    }

    async getTypingStatus(chatGuid: string): Promise<TransactionResult> {
        const action = "check-typing-status";
        this.throwForNoMissingFields(action, [chatGuid]);
        return this.sendApiMessage(action, { chatGuid });
    }

    async shouldOfferContactSharing(chatGuid: string): Promise<TransactionResult> {
        const action = "should-offer-nickname-sharing";
        this.throwForNoMissingFields(action, [chatGuid]);
        const request = new TransactionPromise(TransactionType.OTHER);
        return this.sendApiMessage(action, { chatGuid }, request);
    }

    async shareContactCard(chatGuid: string): Promise<TransactionResult> {
        const action = "share-nickname";
        this.throwForNoMissingFields(action, [chatGuid]);
        return this.sendApiMessage(action, { chatGuid });
    }

    async leave(chatGuid: string): Promise<TransactionResult> {
        const action = "leave-chat";
        this.throwForNoMissingFields(action, [chatGuid]);
        const request = new TransactionPromise(TransactionType.CHAT);
        return this.sendApiMessage(action, { chatGuid }, request);
    }

    async delete(guid: string): Promise<TransactionResult> {
        const action = "delete-chat";
        this.throwForNoMissingFields(action, [guid]);
        const request = new TransactionPromise(TransactionType.CHAT);
        return this.sendApiMessage(action, { chatGuid: guid }, request);
    }
}
