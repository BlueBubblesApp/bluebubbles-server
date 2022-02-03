import { showSuccessToast } from './ToastUtils';

export const testJson = (value: string): NodeJS.Dict<any> | null => {
    try {
        return JSON.parse(value);
    } catch (ex: any) {
        return null;
    }
};

export const readFile = async (file: Blob): Promise<string> => {
    return await new Promise((resolve, reject) => {
        const reader = new FileReader();

        reader.onabort = () => {
            reject(new Error('File reading was aborted'));
        };
        reader.onerror = () => {
            reject(new Error(`File reading failed: ${reader?.error?.message}`));
        };

        reader.onload = () => {
            resolve(reader.result as string);
        };

        reader.readAsText(file);
    });
};

export const getRandomInt = (max: number, min = 0): number => {
    return Math.random() * (max - min) + min;
};

export const hasKey = (object: NodeJS.Dict<any>, key: string): boolean => {
    return Object.keys(object).includes(key);
};

export const buildQrData = (password: string, address: string, fcmClient: NodeJS.Dict<any>): string => {
    if (!fcmClient || fcmClient.length === 0) return '';

    const output = [password, address || ''];

    output.push(fcmClient.project_info.project_id);
    output.push(fcmClient.project_info.storage_bucket);
    output.push(fcmClient.client[0].api_key[0].current_key);
    output.push(fcmClient.project_info.firebase_url);
    const { client_id } = fcmClient.client[0].oauth_client[0];
    output.push(client_id.substr(0, client_id.indexOf('-')));
    output.push(fcmClient.client[0].client_info.mobilesdk_app_id);

    return JSON.stringify(output);
};

export const copyToClipboard = async (data: string) => {
    await navigator.clipboard.writeText(data);
    showSuccessToast({
        description: 'Copied to clipboard!'
    });
};