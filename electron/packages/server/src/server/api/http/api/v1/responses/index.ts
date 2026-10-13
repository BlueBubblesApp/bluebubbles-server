import {
    ResponseFormat,
    ResponseMessages,
    ResponseData,
    ErrorTypes
} from "@server/api/http/api/v1/responses/types";

export const createSuccessResponse = (
    data: ResponseData,
    message?: string,
    metadata?: { [key: string]: any }
): ResponseFormat => {
    const res: ResponseFormat = {
        status: 200,
        message: message || ResponseMessages.SUCCESS,
        data
    };

    if (metadata) {
        res.metadata = metadata;
    }

    return res;
};

export const createServerErrorResponse = (
    error: string,
    errorType?: ErrorTypes,
    message?: string,
    data?: ResponseData
): ResponseFormat => {
    const output: ResponseFormat = {
        status: 500,
        message: message ?? ResponseMessages.SERVER_ERROR,
        error: {
            type: errorType || ErrorTypes.SERVER_ERROR,
            message: error
        }
    };

    if (data) {
        output.data = data;
    }

    return output;
};

export const createBadRequestResponse = (message: string): ResponseFormat => {
    return {
        status: 400,
        message: ResponseMessages.BAD_REQUEST,
        error: {
            type: ErrorTypes.VALIDATION_ERROR,
            message
        }
    };
};

export const createUnauthorizedResponse = (): ResponseFormat => {
    return {
        status: 401,
        message: ResponseMessages.UNAUTHORIZED
    };
};

export const createForbiddenResponse = (): ResponseFormat => {
    return {
        status: 403,
        message: ResponseMessages.FORBIDDEN
    };
};

export const createNotFoundResponse = (message?: string): ResponseFormat => {
    return {
        status: 404,
        message: message ?? ResponseMessages.NOT_FOUND
    };
};

export const createNoDataResponse = (): ResponseFormat => {
    return {
        status: 200,
        message: ResponseMessages.NO_DATA
    };
};
