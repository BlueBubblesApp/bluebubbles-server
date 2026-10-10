export interface RecoverableChatDeleteRequest {
    action: "recoverable-delete-chat";
    data: {
        chatGuid: string;
    };
}

export const recoverableChatDeleteRequest = (chatGuid: string): RecoverableChatDeleteRequest => ({
    action: "recoverable-delete-chat",
    data: { chatGuid }
});
