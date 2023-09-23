import { Server } from "@server";
import {
    TransactionPromise,
    TransactionResult,
    TransactionType
} from "@server/managers/transactionManager/transactionPromise";
import { PrivateApiAction } from ".";


export class PrivateApiFindMy extends PrivateApiAction {

    async getFriendsLocations(): Promise<TransactionResult> {
        const action = "findmy-friends";
        const request = new TransactionPromise(TransactionType.FIND_MY);
        return this.sendApiMessage(action, null, request);
    }
}