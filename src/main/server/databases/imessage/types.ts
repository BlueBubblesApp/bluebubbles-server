export type DBMessageParams = {
    chatGuid?: string;
    offset?: number;
    limit?: number;
    after?: Date | number;
    before?: Date | number;
    withChats?: boolean;
    withChatParticipants?: boolean;
    withAttachments?: boolean;
    withHandle?: boolean;
    sort?: "ASC" | "DESC";
    withSMS?: boolean;
    where?: DBWhereItem[];
};

export type DBWhereItem = {
    statement: string;
    args: { [key: string]: string | number };
};

export type ChatParams = {
    chatGuid?: string;
    withParticipants?: boolean;
    withLastMessage?: boolean;
    withArchived?: boolean;
    withSMS?: boolean;
    offset?: number;
    limit?: number;
};
