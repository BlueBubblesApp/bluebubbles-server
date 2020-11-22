export type DBMessageParams = {
    chatGuid?: string;
    offset?: number;
    limit?: number;
    after?: Date | number;
    before?: Date | number;
    withChats?: boolean;
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
    withArchived?: boolean;
    offset?: number;
    limit?: number;
};
