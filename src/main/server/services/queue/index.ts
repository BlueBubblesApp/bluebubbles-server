import { FileSystem } from "@server/fileSystem";
import { ActionHandler } from "@server/helpers/actions";
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
                    await ActionHandler.sendMessage(
                        item.data.tempGuid,
                        item.data.chatGuid,
                        item.data.message,
                        item.data.attachmentGuid,
                        item.data.attachmentName,
                        item.data.chunks
                    );

                    // After 60 seconds, delete the attachment chunks
                    setTimeout(() => {
                        FileSystem.deleteChunks(item.data.attachmentGuid);
                    }, 60000);
                    break;
                default:
                    Server().log(`Unhandled queue item type: ${item.type}`, "warn");
            }
        } catch (ex) {
            Server().log(`Failed to process queued item; Item type: ${item.type}`, "error");
            Server().log(ex.message);
        }

        // Check and see if there are any other items to process
        if (this.items.length > 0) {
            const nextItem: QueueItem = this.items.shift();
            await this.process(nextItem);
        } else {
            // If there are no other items to process, tell everyone
            // that we are finished processing
            this.isProcessing = false;
        }
    }
}
