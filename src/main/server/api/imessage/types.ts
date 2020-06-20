export type DBMessageParams = {
    chatGuid?: string;
    offset?: number;
    limit?: number;
    after?: Date;
    before?: Date;
    withChats?: boolean;
    withAttachments?: boolean;
    withHandle?: boolean;
    sort?: "ASC" | "DESC";
    where?: DBWhereItem[];
};

export type DBWhereItem = {
    statement: string;
    args: { [key: string]: string | number };
};
