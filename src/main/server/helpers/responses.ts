import { ResponseFormat, ResponseMessages, ResponseData, ErrorTypes } from "@server/helpers/dataTypes";

export const createSuccessResponse = (data: ResponseData, message?: string): ResponseFormat => {
    return {
        status: 200,
        message: message || ResponseMessages.SUCCESS,
        data
    }
};

export const createServerErrorResponse = (
    errorMessage: string,
    errorType?: ErrorTypes,
): ResponseFormat => {
    return {
        status: 500,
        message: ResponseMessages.SERVER_ERROR,
        error: {
            type: errorType || ErrorTypes.SERVER_ERROR,
            message: errorMessage
        }
    };
};

export const createBadRequestResponse = (
    message: string
): ResponseFormat => {
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

export const createNoDataResponse = (): ResponseFormat => {
    return {
        status: 200,
        message: ResponseMessages.NO_DATA
    };
};
