import {
    TransactionPromise,
    TransactionResult,
    TransactionType
} from "@server/managers/transactionManager/transactionPromise";
import { PrivateApiAction } from ".";
import { isMinBigSur, isMinSequoia, isMinSonoma } from "@server/env";
import {
    resolveFindMyDevicesPrivateApiTarget,
    resolveFindMyFriendsPrivateApiTarget
} from "@server/api/lib/findmy/privateApiSupport";

export class PrivateApiFindMy extends PrivateApiAction {
    tag = "PrivateApiFindMy";

    readonly friendsTargetProcessIdentifier = resolveFindMyFriendsPrivateApiTarget({
        isMinBigSur,
        isMinSonoma,
        isMinSequoia
    });

    readonly devicesTargetProcessIdentifier = resolveFindMyDevicesPrivateApiTarget({ isMinSequoia });

    async refreshFriends(): Promise<TransactionResult> {
        if (this.friendsTargetProcessIdentifier == null) {
            throw new Error("The Find My Friends private API is unavailable on this macOS version");
        }

        const action = "refresh-findmy-friends";
        const request = new TransactionPromise(TransactionType.FIND_MY);
        return this.sendApiMessage(action, null, request, this.friendsTargetProcessIdentifier);
    }

    async refreshDevices(): Promise<TransactionResult> {
        if (this.devicesTargetProcessIdentifier == null) {
            throw new Error("The Find My Devices private API is unavailable on this macOS version");
        }

        const action = "refresh-findmy-devices";
        const request = new TransactionPromise(TransactionType.FIND_MY);
        return this.sendApiMessage(action, null, request, this.devicesTargetProcessIdentifier);
    }
}
