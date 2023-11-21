import * as fs from "fs";

export type ValidStatuses = 200 | 201 | 400 | 401 | 403 | 404 | 500 | 504;

export type ResponseData = any;

export enum ResponseMessages {
    SUCCESS = "Success",
    BAD_REQUEST = "Bad Request",
    SERVER_ERROR = "Server Error",
    UNAUTHORIZED = "Unauthorized",
    FORBIDDEN = "Forbidden",
    NO_DATA = "No Data",
    NOT_FOUND = "Not Found",
    UNKNOWN_IMESSAGE_ERROR = "Unknown iMessage Error",
    GATEWAY_TIMEOUT = "Gateway Timeout"
}

export enum ErrorTypes {
    SERVER_ERROR = "Server Error",
    DATABSE_ERROR = "Database Error",
    IMESSAGE_ERROR = "iMessage Error",
    SOCKET_ERROR = "Socket Error",
    VALIDATION_ERROR = "Validation Error",
    AUTHENTICATION_ERROR = "Authentication Error",
    GATEWAY_TIMEOUT = "Gateway Timeout"
}

export type ErrorBody = {
    type: ErrorTypes;
    message: string;
};

export type ResponseJson = {
    status: ValidStatuses;
    message: ResponseMessages | string;
    encrypted?: boolean;
    error?: ErrorBody;
    data?: ResponseData;
    metadata?: { [key: string]: any };
};

export type ResponseFormat = ResponseJson | string | fs.ReadStream;

export type ResponseParams = {
    message?: string;
    error?: string;
    data?: ResponseData;
    metadata?: { [key: string]: any };
};
