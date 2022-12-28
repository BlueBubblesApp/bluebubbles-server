export type DBMessageParams = {
    chatGuid?: string;
    offset?: number;
    limit?: number;
    after?: Date | number;
    before?: Date | number;
    withChats?: boolean;
    withChatParticipants?: boolean;
    withAttachments?: boolean;
    sort?: "ASC" | "DESC";
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
    offset?: number;
    limit?: number;
};

export type HandleParams = {
    address?: string;
    offset?: number;
    limit?: number;
};
