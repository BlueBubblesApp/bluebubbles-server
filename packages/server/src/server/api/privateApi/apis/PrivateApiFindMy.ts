import {
    TransactionPromise,
    TransactionResult,
    TransactionType
} from "@server/managers/transactionManager/transactionPromise";
import { PrivateApiAction } from ".";
import { isMinBigSur, isMinSequoia, isMinSonoma } from "@server/env";
import { resolveFindMyFriendsPrivateApiTarget } from "@server/api/lib/findmy/privateApiSupport";

export class PrivateApiFindMy extends PrivateApiAction {
    tag = "PrivateApiFindMy";

    readonly targetProcessIdentifier = resolveFindMyFriendsPrivateApiTarget({
        isMinBigSur,
        isMinSonoma,
        isMinSequoia
    });

    async refreshFriends(): Promise<TransactionResult> {
        if (this.targetProcessIdentifier == null) {
            throw new Error("The Find My Friends private API is unavailable on this macOS version");
        }

        const action = "refresh-findmy-friends";
        const request = new TransactionPromise(TransactionType.FIND_MY);
        return this.sendApiMessage(action, null, request, this.targetProcessIdentifier);
    }
}
