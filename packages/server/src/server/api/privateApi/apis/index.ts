import { isEmpty } from "@server/helpers/utils";
import type { PrivateApiService } from "../PrivateApiService";
import type { TransactionPromise, TransactionResult } from "@server/managers/transactionManager/transactionPromise";
import { Loggable } from "@server/lib/logging/Loggable";

export class PrivateApiAction extends Loggable {
    tag = "PrivateApiAction";

    api: PrivateApiService;

    constructor(api: PrivateApiService) {
        super();
        this.api = api;
    }

    throwForBadStatus() {
        if (!this.api.helper || !this.api.server) {
            throw new Error("Failed to invoke Private API! Error: BlueBubblesHelper is not running!");
        }
    }

    throwForNoMissingFields(action: string, fields: any[]) {
        for (const field of fields) {
            if (["boolean", "number"].includes(typeof field)) continue;
            if (isEmpty(field)) {
                throw new Error(`Failed to invoke Private API action: ${action}! Required fields are missing.`);
            }
        }
    }

    async sendApiMessage(
        action: string,
        data: NodeJS.Dict<any>,
        transaction?: TransactionPromise
    ): Promise<TransactionResult> {
        this.throwForBadStatus();
        return await this.api.writeData(action, data, transaction);
    }
}
