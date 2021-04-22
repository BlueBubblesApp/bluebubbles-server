import { IdentifierInfo, IPluginTypes } from "./types";

export const getPluginIdentifier = (type: IPluginTypes, name: string) => {
    return `${type}.${name}`;
};

export const parseIdentifier = (identifier: string): IdentifierInfo => {
    if (!identifier.includes(".") || identifier.split(".").length < 2) {
        throw new Error(`Invalid plugin identifier: ${identifier}`);
    }

    const pieces = identifier.split(".");
    return { type: pieces[0] as IPluginTypes, name: pieces[1] };
};
