import { hasKey, testJson } from './GenericUtils';

export const isValidClientConfig = (value: string): boolean => {
    const data = testJson(value);
    if (!data) return false;

    if (!hasKey(data, 'project_info')) return false;
    if (!hasKey(data, 'client')) return false;
    if (!hasKey(data, 'configuration_version')) return false;

    return true;
};

export const isValidServerConfig = (value: string): boolean => {
    const data = testJson(value);
    if (!data) return false;

    if (!hasKey(data, 'project_id')) return false;
    if (!hasKey(data, 'private_key_id')) return false;
    if (!hasKey(data, 'private_key')) return false;
    return true;
};

export const isValidFirebaseUrl = (config: NodeJS.Dict<any>): boolean => {
    return config?.project_info?.firebase_url !== null;
};