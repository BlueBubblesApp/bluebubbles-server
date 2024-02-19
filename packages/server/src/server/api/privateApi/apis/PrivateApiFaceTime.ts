import {
    TransactionPromise,
    TransactionResult,
    TransactionType
} from "@server/managers/transactionManager/transactionPromise";
import { PrivateApiAction } from ".";

export class PrivateApiFaceTime extends PrivateApiAction {
    tag = "PrivateApiFaceTime";

    async answerCall(uuid: string): Promise<TransactionResult> {
        const action = "answer-call";
        const request = new TransactionPromise(TransactionType.OTHER);
        return this.sendApiMessage(action, { callUUID: uuid }, request);
    }

    async leaveCall(uuid: string): Promise<TransactionResult> {
        const action = "leave-call";
        return this.sendApiMessage(action, { callUUID: uuid });
    }

    async generateLink(uuid: string = null): Promise<TransactionResult> {
        const action = "generate-link";
        const request = new TransactionPromise(TransactionType.OTHER);

        const args: Record<string, any> = {};
        args["callUUID"] = uuid ?? null;

        return this.sendApiMessage(action, args, request);
    }

    async admitParticipant(conversationUuid: string, handleUuid: string): Promise<TransactionResult> {
        const action = "admit-pending-member";
        const request = new TransactionPromise(TransactionType.OTHER);
        return this.sendApiMessage(
            action,
            {
                conversationUUID: conversationUuid,
                handleUUID: handleUuid
            },
            request
        );
    }
}
