import { webhookEventOptions } from '../constants';
import { MultiSelectValue } from '../types';
import { showSuccessToast } from './ToastUtils';


export const waitMs = async (ms: number) => {
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    return new Promise((resolve, _) => setTimeout(resolve, ms));
};

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

export const buildQrData = (password: string, address: string): string => {
    return JSON.stringify([password, address ?? '']);
};

export const copyToClipboard = async (data: string) => {
    await navigator.clipboard.writeText(data);
    showSuccessToast({
        description: 'Copied to clipboard!'
    });
};

export const webhookEventValueToLabel = (value: string) => {
    const output = webhookEventOptions.filter(e => e.value === value).map(e => e.label);
    return output && output.length > 0 ? output[0] : 'Unknown';
};

export const convertMultiSelectValues = (values: Array<string>): Array<MultiSelectValue> => {
    const output: Array<MultiSelectValue> = [];
    for (const i of values) {
        output.push({
            value: i,
            label: webhookEventValueToLabel(i)
        });
    }

    return output;
};