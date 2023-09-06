import { Server } from "@server";
import {
    TransactionPromise,
    TransactionResult,
    TransactionType
} from "@server/managers/transactionManager/transactionPromise";
import { PrivateApiAction } from ".";


export class PrivateApiCloud extends PrivateApiAction {

    async getAccountInfo(): Promise<TransactionResult> {
        const action = "get-account-info";
        const request = new TransactionPromise(TransactionType.OTHER);
        return this.sendApiMessage(action, null, request);
    }
}