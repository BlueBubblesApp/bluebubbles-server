import {
    TransactionPromise,
    TransactionResult,
    TransactionType
} from "@server/managers/transactionManager/transactionPromise";
import { PrivateApiAction } from ".";

export class PrivateApiCloud extends PrivateApiAction {
    tag = "PrivateApiCloud";

    async getAccountInfo(): Promise<TransactionResult> {
        const action = "get-account-info";
        const request = new TransactionPromise(TransactionType.OTHER);
        return this.sendApiMessage(action, null, request);
    }

    async getContactCard(address: string = null): Promise<TransactionResult> {
        const action = "get-nickname-info";
        const request = new TransactionPromise(TransactionType.OTHER);
        return this.sendApiMessage(action, { address }, request);
    }

    async modifyActiveAlias(alias: string): Promise<TransactionResult> {
        const action = "modify-active-alias";
        const request = new TransactionPromise(TransactionType.OTHER);
        return this.sendApiMessage(action, { alias }, request);
    }
}
