import { Server } from "@server/index";
import { Chat } from "@server/databases/imessage/entity/Chat";
import { Message } from "@server/databases/imessage/entity/Message";
import { isNotEmpty, onlyAlphaNumeric } from "@server/helpers/utils";

export class MessagePromise {
    promise: Promise<Message>;

    private resolvePromise: (value: Message | PromiseLike<Message>) => void;

    private rejectPromise: (reason?: any) => void;

    text: string;

    chatGuid: string;

    sentAt: number;

    isResolved = false;

    errored = false;

    error: any;

    isAttachment: boolean;

    private tempGUID?: string | null;

    constructor(chatGuid: string, text: string, isAttachment: boolean, sentAt: Date | number, subject?: string, tempGUID?: string) {

        // Used to temporarily update the guid
        this.tempGUID = tempGUID;

        // Create a promise and save the "callbacks"
        this.promise = new Promise((resolve, reject) => {
            this.resolvePromise = resolve;
            this.rejectPromise = reject;
        });

        // Hook into the resolve and rejects so we can set flags based on the status
        this.promise.catch((err: any) => {
            this.errored = true;
            this.error = err;
        });

        this.chatGuid = chatGuid;
        this.text = `${subject ?? ""}${text ?? ""}`;
        this.isAttachment = isAttachment;

        // Subtract 10 seconds to account for any "delay" in the sending process (somehow)
        this.sentAt = typeof sentAt === "number" ? sentAt : sentAt.getTime();

        // If this is an attachment, we don't need to compare the message text
        if (!this.isAttachment) {
            this.text = onlyAlphaNumeric(this.text);
        }

        // Create a timeout for how long until we "error-out".
        // Timeouts should change based on if it's an attachment or message
        // 3 minute timeout for attachments
        // 30 second timeout for messages
        setTimeout(
            () => {
                if (this.isResolved) return;

                // This will trigger our hook handlers, created in the constructor
                this.reject("Message send timeout");
            },
            this.isAttachment ? 60000 * 3 : 30000
        );
    }

    async resolve(value: Message) {
        this.isResolved = true;
        await this.updateMessageMatch(value);
        this.resolvePromise(value);
    }

    reject(reason?: any) {
        this.isResolved = true;
        this.rejectPromise(reason);
    }

    async updateMessageMatch(sentMessage: Message) {
        // If we have a sent message and we have a tempGuid, we need to emit the message match event
        if (sentMessage && isNotEmpty(this.tempGUID)) {
            Server().httpService.sendCache.remove(this.tempGUID);
            await Server().emitMessageMatch(sentMessage, this.tempGUID);
        }
    }

    isSame(message: Message) {
        // We can only set one attachment at a time, so we will check that one
        // Images will have an invisible character as the text (of length 1)
        // So if it's an attachment, and doesn't meet the criteria, return false
        const matchTxt = `${message.subject ?? ""}${message.text ?? ""}`;
        if (this.isAttachment && ((message.attachments ?? []).length > 1 || matchTxt.length > 1)) {
            return false;
        }

        // If we have chats, we need to make sure this promise is for that chat
        // We use endsWith to support when the chatGuid is just an address
        if (isNotEmpty(message.chats) && !message.chats.some((c: Chat) => c.guid.endsWith(this.chatGuid))) {
            return false;
        }

        // If this is an attachment, we need to match it slightly differently
        if (this.isAttachment) {
            if ((message.attachments ?? []).length > 1 || matchTxt.length > 1) {
                return false;
            }

            // If the transfer names match, congratz we have a match
            return message.attachments[0].transferName.endsWith(this.text.split("->")[1]);
        }

        return this.text === onlyAlphaNumeric(message.text) && this.sentAt < message.dateCreated.getTime();
    }
}
