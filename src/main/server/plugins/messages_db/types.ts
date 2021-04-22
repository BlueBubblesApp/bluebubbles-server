export type MessageSpec = MessageDbSpec | MessageItemSpec;
export type HandleSpec = HandleDbSpec | HandleItemSpec;
export type ChatSpec = ChatDbSpec | ChatItemSpec;
export type AttachmentSpec = AttachmentDbSpec | AttachmentItemSpec;

export type MessageDbSpec = {
    originalROWID: number;
    tempGuid?: string;
    guid: string;
    text: string | null;
    replace?: boolean;
    serviceCenter?: string | null;
    originalHandleId?: number;
    subject?: string | null;
    country?: string | null;
    attributedBody?: Blob | null;
    version?: number;
    type?: number;
    service?: string;
    error: number;
    date: number;
    dateRead: number;
    dateDelivered: number;
    isFinished: boolean;
    isEmote: boolean;
    isFromMe: boolean;
    isEmpty: boolean;
    isDelayed: boolean;
    isAutoReply: boolean;
    isPrepared: boolean;
    isRead: boolean;
    isSystemMessage: boolean;
    isSent: boolean;
    hasDdResults: boolean;
    isServiceMessage: boolean;
    isForward: boolean;
    wasDowngraded: boolean;
    isArchive?: boolean;
    cacheHasAttachments?: boolean;
    cacheRoomnames?: string | null;
    wasDataDetected: boolean;
    isAudioMessage: boolean;
    isPlayed: boolean;
    datePlayed: number;
    itemType: number;
    originalOtherHandle?: number;
    groupTitle: string | null;
    groupActionType: number;
    shareStatus?: number;
    shareDirection?: number;
    isExpirable?: boolean;
    expireState?: number;
    messageActionType?: number;
    messageSource?: number;
    associatedMessageGuid: string | null;
    associatedMessageType: number;
    balloonBundleId: string | null;
    payloadData?: Blob | null;
    expressiveSendStyleId: string | null;
    associatedMessageRangeLocation?: number;
    associatedMessageRangeLength?: number;
    timeExpressiveSendPlayed: number;
    messageSummaryInfo?: Blob;
    isCorrupt?: boolean;
    replyToGuid?: string;
    isSpam?: boolean;

    // Relationships
    handle?: HandleDbSpec | null;
    chats?: ChatDbSpec[];
    attachments?: AttachmentDbSpec[];
};

export type HandleDbSpec = {
    originalROWID?: number;
    address: string;
    country: string;
    service?: string;
    uncanonicalizedId?: string;
    personCentricId?: string;

    // Relationships
    messages?: MessageDbSpec[];
    chats?: ChatDbSpec[];
};

export type ChatDbSpec = {
    originalROWID?: number;
    guid: string;
    style?: number;
    state?: number;
    properties?: Blob;
    chatIdentifier: string;
    service?: string;
    roomName?: string;
    isArchived?: boolean;
    displayName: string;
    groupId?: string;
    isFiltered?: boolean;
    lastReadMessageTimestamp?: number;

    // Relationships
    participants?: HandleDbSpec[];
    messages?: MessageDbSpec[];
};

export type AttachmentDbSpec = {
    originalROWID: number;
    guid: string;
    createdDate: number;
    startDate: number;
    originalPath: string;
    uti: string;
    mimeType: string | null;
    transferState: number;
    isOutgoing: boolean;
    userInfo?: Blob | null;
    transferName: string;
    totalBytes: number;
    isSticker: boolean;
    stickerUserInfo?: Blob | null;
    attributionInfo?: Blob | null;
    hideAttachment?: boolean;

    // Some extras I added in
    data?: string; // Base64 string
    blurhash?: string;
    height?: number;
    width?: number;
    metadata?: { [key: string]: string | boolean | number };

    // Relationships
    messages?: MessageDbSpec[];
};

export type AttachmentItemSpec = {
    // TODO to match WeMessage
};

export type HandleItemSpec = {
    // TODO to match WeMessage
};

export type MessageItemSpec = {
    // TODO to match WeMessage
};

export type ChatItemSpec = {
    // TODO to match WeMessage
};

export type TypeOrmWhereParam = {
    statement: string;
    args: { [key: string]: string | number };
};

export type GetChatsParams = {
    guid?: string;
    withHandles?: boolean;
    withMessages?: boolean;
    includeArchived?: boolean;
    includeSms?: boolean;
    offset?: number;
    limit?: number;
    where?: TypeOrmWhereParam[];
};

export type GetAttachmentsParams = {
    guid?: string;
    withData?: boolean;
    withMessages?: boolean;
    offset?: number;
    limit?: number;
    where?: TypeOrmWhereParam[];
};

export type GetHandlesParams = {
    address?: string;
    chatIdentifier?: string;
    withChats?: boolean;
    offset?: number;
    limit?: number;
    where?: TypeOrmWhereParam[];
};

export type GetMessagesParams = {
    guid?: string;
    chatGuid?: string;
    associatedMessageGuid?: string;
    withChats?: boolean;
    withHandle?: boolean;
    withOtherHandle?: boolean;
    withAttachments?: boolean;
    withAttachmentsData?: boolean;
    includeSms?: boolean;
    before?: number | Date;
    after?: number | Date;
    offset?: number;
    limit?: number;
    sort?: "ASC" | "DESC";
    where?: TypeOrmWhereParam[];
};
