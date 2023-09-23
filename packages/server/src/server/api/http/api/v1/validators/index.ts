import Validator, { ValidationErrors } from "validatorjs";
import { isNotEmpty } from "@server/helpers/utils";
import { BadRequest } from "../responses/errors";

Validator.register(
    "json-object",
    (value, requirement, attribute) => {
        return typeof value === "object" && value !== null;
    },
    "The :attribute must be a valid json object."
);

export const getFirstError = (errors: ValidationErrors) => {
    for (const err of Object.keys(errors)) {
        if (isNotEmpty(errors[err])) {
            return errors[err][0];
        }
    }

    return null;
};

export const ValidateInput = <T>(data: T, rules: NodeJS.Dict<string>): T => {
    const validation = new Validator(data, rules);
    if (validation.fails()) {
        throw new BadRequest({ error: getFirstError(validation.errors.all()) });
    }

    return data;
};

export const ValidateJSON = (data: any, errorPrefix?: string) => {
    const errStr = errorPrefix ? `${errorPrefix} data` : "Data";
    if (!data) {
        throw new BadRequest({ error: `${errStr} must be a JSON object!` });
    }

    if (typeof data !== "object" || Array.isArray(data)) {
        throw new BadRequest({ error: `${errStr} must be a JSON object!` });
    }

    return data;
};

export const ValidateNumber = (value: string, errorPrefix?: string): number => {
    // If it's empty, we don't need to throw an error
    if (!value) return null;

    const errStr = errorPrefix ?? "Input";
    let parsed: number;

    try {
        parsed = Number.parseInt(value, 10);
        if (parsed < 0) return null;
    } catch (ex) {
        throw new BadRequest({ error: `${errStr} must be a valid number!` });
    }

    // If all the other conditions fail, default to best
    return parsed;
};
