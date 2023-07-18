import { isEmpty } from "@server/helpers/utils";
import type { PrivateApiService } from "../PrivateApiService";
import type { TransactionPromise, TransactionResult } from "@server/managers/transactionManager/transactionPromise";

export class PrivateApiAction {

    api: PrivateApiService;

    constructor(api: PrivateApiService) {
        this.api = api;
    }

    throwForBadStatus() {
        if (!this.api.helper || !this.api.server) {
            throw new Error("Failed to invoke Private API! Error: BlueBubblesHelper is not running!");
        }
    }

    throwForNoMissingFields(action: string, fields: any[]) {
        for (const field of fields) {
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