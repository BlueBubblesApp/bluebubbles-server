import { Chat } from "@server/databases/imessage/entity/Chat";
import { Message } from "@server/databases/imessage/entity/Message";
import { onlyAlphaNumeric } from "@server/helpers/utils";

export class MessagePromise {
    promise: Promise<Message>;

    resolve: (value: Message | PromiseLike<Message>) => void;

    reject: (reason?: any) => void;

    text: string;

    chatGuid: string;

    sentAt: number;

    isResolved = false;

    errored = false;

    error: any;

    isAttachment: boolean;

    constructor(chatGuid: string, text: string, isAttachment: boolean, sentAt: Date | number) {
        // Create a promise and save the "callbacks"
        this.promise = new Promise((resolve, reject) => {
            this.resolve = resolve;
            this.reject = reject;
        });

        // Hook into the resolve and rejects so we can set flags based on the status
        this.promise
            .then((_: any) => {
                this.isResolved = true;
            })
            .catch((err: any) => {
                this.isResolved = true;
                this.errored = true;
                this.error = err;
            });

        this.chatGuid = chatGuid;
        this.text = text;
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

    isSame(message: Message) {
        // We can only set one attachment at a time, so we will check that one
        // Images will have an invisible character as the text (of length 1)
        // So if it's an attachment, and doesn't meet the criteria, return false
        if (this.isAttachment && ((message.attachments ?? []).length > 1 || (message.text ?? "").length > 1)) {
            return false;
        }

        // If we have chats, we need to make sure this promise is for that chat
        if (message.chats.length > 0 && !message.chats.some((c: Chat) => c.guid === this.chatGuid)) {
            return false;
        }

        // If this is an attachment, we need to match it slightly differently
        if (this.isAttachment) {
            if ((message.attachments ?? []).length > 1 || (message.text ?? "").length > 1) {
                return false;
            }

            // If the transfer names match, congratz we have a match
            return message.attachments[0].transferName.endsWith(this.text.split("->")[1]);
        }

        return this.text === onlyAlphaNumeric(message.text) && this.sentAt < message.dateCreated.getTime();
    }
}
