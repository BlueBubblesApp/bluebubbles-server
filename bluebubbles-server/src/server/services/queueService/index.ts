import { MessageInterface } from "@server/api/v1/interfaces/messageInterface";
import { FileSystem } from "@server/fileSystem";
import { ActionHandler } from "@server/api/v1/apple/actions";
import { isNotEmpty } from "@server/helpers/utils";
import { Server } from "@server/index";

export type QueueItem = {
    type: string;
    data: any;
};

export class QueueService {
    items: QueueItem[] = [];

    isProcessing = false;

    async add(item: QueueItem) {
        if (this.isProcessing) {
            // If we are already processing, add item to the queue
            Server().log("QueueService is already working. Adding item to queue.", "debug");
            this.items.push(item);
        } else {
            // If we aren't processing, process the next item
            // This doesn't need to be awaited on
            this.process(item);
        }
    }

    private async process(item: QueueItem): Promise<void> {
        // Tell everyone we are currently processing
        this.isProcessing = true;
        Server().log(`Processing next item in the queue; Item type: ${item.type}`);

        // Handle the event
        try {
            Server().log(`Handling queue item, '${item.type}'`);
            switch (item.type) {
                case "open-chat":
                    await ActionHandler.openChat(item.data);
                    break;
                case "send-attachment":
                    // Send the attachment first
                    try {
                        await MessageInterface.sendAttachmentSync(
                            item.data.chatGuid,
                            item.data.attachmentPath,
                            item.data.attachmentName,
                            item.data.attachmentGuid
                        );
                        Server().httpService.sendCache.remove(item?.data?.attachmentGuid);
                    } catch (ex: any) {
                        // Re-throw the error after removing from cache
                        Server().httpService.sendCache.remove(item?.data?.attachmentGuid);
                        throw ex;
                    }

                    // Then send the message (if required)
                    if (isNotEmpty(item.data.message)) {
                        try {
                            await MessageInterface.sendMessageSync(
                                item.data.chatGuid,
                                item.data.message,
                                "apple-script",
                                null,
                                null,
                                null,
                                item.data.tempGuid
                            );
                        } finally {
                            // Remove from cache
                            Server().httpService.sendCache.remove(item?.data?.tempGuid);
                        }
                    }

                    // After 30 minutes, delete the attachment chunks
                    setTimeout(() => {
                        FileSystem.deleteChunks(item.data.attachmentGuid);
                    }, 1000 * 60 * 30);
                    break;
                default:
                    Server().log(`Unhandled queue item type: ${item.type}`, "warn");
            }
        } catch (ex: any) {
            Server().log(`Failed to process queued item; Item type: ${item.type}`, "error");
            Server().log(ex?.message ?? ex, "debug");
        }

        // Check and see if there are any other items to process
        if (isNotEmpty(this.items)) {
            const nextItem: QueueItem = this.items.shift();
            await this.process(nextItem);
        } else {
            // If there are no other items to process, tell everyone
            // that we are finished processing
            this.isProcessing = false;
        }
    }
}
