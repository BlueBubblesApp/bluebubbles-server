import {
    TransactionPromise,
    TransactionResult,
    TransactionType
} from "@server/managers/transactionManager/transactionPromise";
import { PrivateApiAction } from ".";

export class PrivateApiFindMy extends PrivateApiAction {
    tag = "PrivateApiFindMy";

    async refreshFriends(): Promise<TransactionResult> {
        const action = "refresh-findmy-friends";
        const request = new TransactionPromise(TransactionType.FIND_MY);
        return this.sendApiMessage(action, null, request);
    }
}
