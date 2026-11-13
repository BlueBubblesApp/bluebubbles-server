/* eslint-disable max-classes-per-file */
import { ResponseParams, ErrorTypes, ResponseFormat, ResponseMessages, ValidStatuses, ResponseJson } from "./types";

export class HTTPError extends Error {
    response: ResponseFormat;

    status: ValidStatuses;

    constructor(response: ResponseJson) {
        super(`[${response.status}] ${response.message}`);
        this.name = this.constructor.name;
        this.response = response;
        this.status = response.status;

        Error.captureStackTrace(this, this.constructor);
    }
}

export class Unauthorized extends HTTPError {
    constructor(response?: ResponseParams) {
        super({
            status: 401,
            message: response?.message ?? "You are not authorized to access this resource",
            error: {
                type: ErrorTypes.AUTHENTICATION_ERROR,
                message: response?.error ?? ResponseMessages.UNAUTHORIZED
            },
            data: response?.data
        });
    }
}

export class Forbidden extends HTTPError {
    constructor(response?: ResponseParams) {
        super({
            status: 403,
            message: response?.message ?? "You are forbidden from accessing this resource",
            error: {
                type: ErrorTypes.AUTHENTICATION_ERROR,
                message: response?.error ?? ResponseMessages.FORBIDDEN
            },
            data: response?.data
        });
    }
}

export class BadRequest extends HTTPError {
    constructor(response?: ResponseParams) {
        super({
            status: 400,
            message: response?.message ?? "You've made a bad request! Please check your request params & body",
            error: {
                type: ErrorTypes.VALIDATION_ERROR,
                message: response?.error ?? ResponseMessages.BAD_REQUEST
            },
            data: response?.data
        });
    }
}

export class NotFound extends HTTPError {
    constructor(response?: ResponseParams) {
        super({
            status: 404,
            message: response?.message ?? "The requested resource was not found",
            error: {
                type: ErrorTypes.DATABSE_ERROR,
                message: response?.error ?? ResponseMessages.NOT_FOUND
            },
            data: response?.data
        });
    }
}

export class ServerError extends HTTPError {
    constructor(response?: ResponseParams) {
        super({
            status: 500,
            message: response?.message ?? "The server has encountered an error",
            error: {
                type: ErrorTypes.SERVER_ERROR,
                message: response?.error ?? ResponseMessages.SERVER_ERROR
            },
            data: response?.data
        });
    }
}

export class GatewayTimeout extends HTTPError {
    constructor(response?: ResponseParams) {
        super({
            status: 504,
            message: response?.message ?? `The server took too long to response!`,
            error: {
                type: ErrorTypes.GATEWAY_TIMEOUT,
                message: response?.error ?? ResponseMessages.GATEWAY_TIMEOUT
            },
            data: response?.data
        });
    }
}

export class IMessageError extends HTTPError {
    constructor(response?: ResponseParams) {
        super({
            status: 500,
            message: response?.message ?? "iMessage has encountered an error",
            error: {
                type: ErrorTypes.IMESSAGE_ERROR,
                message: response?.error ?? ResponseMessages.UNKNOWN_IMESSAGE_ERROR
            },
            data: response?.data
        });
    }
}
