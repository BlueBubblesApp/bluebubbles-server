import { FileSystem } from "@server/fileSystem";
import { isNotEmpty } from "@server/helpers/utils";
import { Message } from "@server/databases/imessage/entity/Message";
import { MessageResponse } from "@server/types";
import { Server } from "@server";

/**
 * A class that handles the communication with the swift helper process.
 */
export class ObjCHelperService {
    static async bulkDeserializeAttributedBody(messages: Message[] | MessageResponse[]): Promise<any[]> {
        const helperPath = `${FileSystem.resources}/bluebubblesObjcHelper`;

        try {
            const msgs = [];
            for (const i of messages) {
                if (isNotEmpty(i.attributedBody)) {
                    const buff = Buffer.from(i.attributedBody);
                    msgs.push({
                        id: i.guid,
                        payload: buff.toString("base64")
                    });
                }
            }

            // Send the request to the helper
            // Don't use double-quotes around the payload or else it'll break the command
            const payload = JSON.stringify({ type: "bulk-attributed-body", data: msgs });
            const data = await FileSystem.execShellCommand(`${helperPath} '${payload}'`);
            const json = data.substring(data.indexOf("] ") + 2);
            return JSON.parse(json);
        } catch (ex: any) {
            Server().log(`Failed to deserialize attributed bodies! Error: ${ex?.message ?? String(ex)}`);
            return null;
        }
    }
}
