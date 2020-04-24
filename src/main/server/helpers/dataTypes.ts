export type ValidStatuses = 200 | 201 | 400 | 401 | 403 | 404 | 500;

export type Error = {
    type: ErrorTypes;
    message: string;
};

export type ResponseData = MessageResponse | HandleResponse | ChatResponse | (MessageResponse | HandleResponse | ChatResponse)[] | null;

export type ResponseFormat = {
    status: ValidStatuses;
    message: ResponseMessages | string;
    error?: Error;
    // Single or list of database objects, or null
    data?: ResponseData;
};

export type MessageResponse = {
    guid: string;
    text: string;
    from?: HandleResponse | null;
    chats?: ChatResponse[];
    subject: string;
    country: string;
    error: boolean;
    dateCreated: number;
    dateRead: number | null;
    dateDelivered: number | null;
    isFromMe: boolean;
    isDelayed: boolean;
    isAutoReply: boolean;
    isSystemMessage: boolean;
    isServiceMessage: boolean;
    isForward: boolean;
    isArchived: boolean;
    cacheRoomnames: string | null;
    isAudioMessage: boolean;
    datePlayed: number | null;
    itemType: number;
    groupTitle: string | null;
    isExpired: boolean;
    associatedMessageGuid: string | null;
    associatedMessageType: number | null;
    expressiveSendStyleId: string | null;
    timeExpressiveSendStyleId: number | null;
};

export type HandleResponse = {
    messages?: MessageResponse[];
    chats?: ChatResponse[];
    id: string;
    country: string;
    uncanonicalizedId: string
};

export type ChatResponse = {
    guid: string;
    participants?: HandleResponse[];
    messages?: MessageResponse[];
    style: number;
    chatIdentifier: string;
    isArchived: boolean;
    displayName: string;
    groupId: string;
}

export enum ResponseMessages {
    SUCCESS = 'Success',
    BAD_REQUEST = 'Bad Request',
    SERVER_ERROR = 'Server Error',
    UNAUTHORIZED = 'Unauthorized',
    FORBIDDEN = 'Forbidden',
    NO_DATA = 'No Data'
};

export enum ErrorTypes {
    SERVER_ERROR = "Server Error",
    DATABSE_ERROR = "Database Error",
    IMESSAGE_ERROR = "iMessage Error",
    SOCKET_ERROR = "Socket Error",
    VALIDATION_ERROR = "Validation Error"
};

