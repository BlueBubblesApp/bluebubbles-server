import { Server } from "@server";
import {
    TransactionPromise,
    TransactionResult,
    TransactionType
} from "@server/managers/transactionManager/transactionPromise";
import { PrivateApiAction } from ".";
import type { ValidTapback, ValidRemoveTapback } from "@server/types";


export class PrivateApiMessage extends PrivateApiAction {

    async send(
        chatGuid: string,
        message: string,
        attributedBody: Record<string, any> = null,
        subject: string = null,
        effectId: string = null,
        selectedMessageGuid: string = null,
        partIndex = 0,
        ddScan = false
    ): Promise<TransactionResult> {
        const action = "send-message";
        this.throwForNoMissingFields(action, [chatGuid, message]);
        const request = new TransactionPromise(TransactionType.MESSAGE);
        return this.sendApiMessage(
            "send-message",
            {
                chatGuid,
                subject,
                message,
                attributedBody,
                effectId,
                selectedMessageGuid,
                partIndex,
                ddScan: ddScan ? 1 : 0
            },
            request
        );
    }

    async sendMultipart(
        chatGuid: string,
        parts: Record<string, any>[],
        attributedBody: Record<string, any> = null,
        subject: string = null,
        effectId: string = null,
        selectedMessageGuid: string = null,
        partIndex = 0,
        ddScan = false
    ): Promise<TransactionResult> {
        const action = "send-multipart";
        this.throwForNoMissingFields(action, [chatGuid, parts]);
        const request = new TransactionPromise(TransactionType.MESSAGE);
        return this.sendApiMessage(
            action,
            {
                chatGuid,
                subject,
                parts,
                attributedBody,
                effectId,
                selectedMessageGuid,
                partIndex,
                ddScan: ddScan ? 1 : 0
            },
            request
        );
    }

    async react(
        chatGuid: string,
        selectedMessageGuid: string,
        reactionType: ValidTapback | ValidRemoveTapback,
        partIndex?: number
    ): Promise<TransactionResult> {
        const action = 'send-reaction';
        this.throwForNoMissingFields(action, [chatGuid, selectedMessageGuid, reactionType]);

        const request = new TransactionPromise(TransactionType.MESSAGE);
        return this.sendApiMessage(
            action,
            {
                chatGuid,
                selectedMessageGuid,
                reactionType,
                partIndex: partIndex ?? 0
            },
            request
        );
    }

    async edit({
        chatGuid,
        messageGuid,
        editedMessage,
        backwardsCompatMessage,
        partIndex
    }: {
        chatGuid: string;
        messageGuid: string;
        editedMessage: string;
        backwardsCompatMessage: string;
        partIndex: number;
    }): Promise<TransactionResult> {
        const action = "edit-message";
        this.throwForNoMissingFields(action, [chatGuid, messageGuid, editedMessage, backwardsCompatMessage, partIndex]);
        const request = new TransactionPromise(TransactionType.MESSAGE);
        return this.sendApiMessage(
            action,
            {
                chatGuid,
                messageGuid,
                editedMessage,
                backwardsCompatibilityMessage: backwardsCompatMessage,
                partIndex
            },
            request
        );
    }

    async unsend({
        chatGuid,
        messageGuid,
        partIndex
    }: {
        chatGuid: string;
        messageGuid: string;
        partIndex: number;
    }): Promise<TransactionResult> {
        const action = "unsend-message";
        this.throwForNoMissingFields(action, [chatGuid, messageGuid, partIndex]);

        const request = new TransactionPromise(TransactionType.MESSAGE);
        return this.sendApiMessage(
            action,
            {
                chatGuid,
                messageGuid,
                partIndex
            },
            request
        );
    }

    async getEmbeddedMedia(chatGuid: string, messageGuid: string): Promise<TransactionResult> {
        const action = "balloon-bundle-media-path";
        this.throwForNoMissingFields(action, [chatGuid, messageGuid]);
        const request = new TransactionPromise(TransactionType.MESSAGE);
        return this.sendApiMessage(action, { chatGuid, messageGuid }, request);
    }

    async notify(chatGuid: string, messageGuid: string): Promise<TransactionResult> {
        const action = "notify-anyways";
        this.throwForNoMissingFields(action, [chatGuid, messageGuid]);
        const request = new TransactionPromise(TransactionType.MESSAGE);
        return this.sendApiMessage(action, { chatGuid, messageGuid }, request);
    }
}