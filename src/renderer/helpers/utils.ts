export const testJson = (value: string) => {
    try {
        return JSON.parse(value);
    } catch (ex) {
        return false;
    }
};

export const isValidClientConfig = (value: string): boolean => {
    const data = testJson(value);
    if (!data) return false;

    if (!Object.keys(data).includes("project_info")) return false;
    if (!Object.keys(data).includes("client")) return false;
    if (!Object.keys(data).includes("configuration_version")) return false;

    return true;
};

export const isValidServerConfig = (value: string): boolean => {
    const data = testJson(value);
    if (!data) return false;

    if (!Object.keys(data).includes("project_id")) return false;
    if (!Object.keys(data).includes("private_key_id")) return false;
    if (!Object.keys(data).includes("private_key")) return false;

    return true;
};
