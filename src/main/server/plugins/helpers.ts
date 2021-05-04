import { IdentifierInfo, IPluginConfigPropItem, IPluginTypes } from "./types";

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

export const isNullish = (value: any): boolean => {
    return [null, undefined, 0, false, "", {}, "{}", [], "[]"].includes(value);
};

export const checkForUpdatedPluginProps = (
    properties1: IPluginConfigPropItem[],
    properties2: IPluginConfigPropItem[]
): boolean => {
    const props1 = properties1.map(item => item.name); // Filter to just a list of names
    const props2 = properties2.map(item => item.name); // Filter to just a list of names
    const missing1 = props1.filter(item => props2.indexOf(item) < 0); // See if any don't exist on the other
    const missing2 = props1.filter(item => props2.indexOf(item) < 0); // See if any don't exist on the other

    // Return true if there are any missing from either
    return missing1.length > 0 || missing2.length > 0;
};
