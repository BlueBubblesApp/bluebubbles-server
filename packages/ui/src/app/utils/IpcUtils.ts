import { ScheduledMessageItem } from 'app/components/tables/ScheduledMessagesTable';
import { ipcRenderer } from 'electron';
import { MultiSelectValue } from '../types';
import { showErrorToast, showSuccessToast } from './ToastUtils';

export const getConfig = async () => {
    return await ipcRenderer.invoke('get-config');
};

export type FcmConfig = {
    fcm_client: string;
    fcm_server: string
};

export const getFcmConfig = async (): Promise<FcmConfig> => {
    const client = await ipcRenderer.invoke('get-fcm-client');
    const server = await ipcRenderer.invoke('get-fcm-server');
    return {
        fcm_client: client,
        fcm_server: server
    };
};

export const getEnv = async () => {
    return await ipcRenderer.invoke('get-env');
};

export const getDevices = async () => {
    return await ipcRenderer.invoke('get-devices');
};

export const getAlerts = async () => {
    return await ipcRenderer.invoke('get-alerts');
};

export const openLogLocation = async () => {
    return await ipcRenderer.invoke('open-log-location');
};

export const openAppLocation = async () => {
    return await ipcRenderer.invoke('open-app-location');
};

export const restartViaTerminal = async () => {
    return await ipcRenderer.invoke('restart-via-terminal');
};

export const restartServices = async () => {
    return await ipcRenderer.invoke('hot-restart');
};

export const fullRestart = async () => {
    return await ipcRenderer.invoke('full-restart');
};

export const clearDevices = async () => {
    return await ipcRenderer.invoke('purge-devices');
};

export const clearEventCache = async () => {
    return await ipcRenderer.invoke('purge-event-cache');
};

export const getPrivateApiRequirements = async () => {
    return await ipcRenderer.invoke('get-private-api-requirements');
};

export const checkPermissions = async () => {
    return await ipcRenderer.invoke('check-permissions');
};

export const getWebhooks = async () => {
    return await ipcRenderer.invoke('get-webhooks');
};

export const createWebhook = async (payload: { url: string, events: Array<MultiSelectValue> }) => {
    return await ipcRenderer.invoke('create-webhook', payload);
};

export const deleteWebhook = async ({ url = null, id = null }: { url?: string | null, id?: number | null }) => {
    return await ipcRenderer.invoke('delete-webhook', { url, id });
};

export const updateWebhook = async ({ id, url, events }: { id: number, url?: string, events?: Array<MultiSelectValue> }) => {
    return await ipcRenderer.invoke('update-webhook', { id, url, events });
};

export const reinstallHelperBundle = async () => {
    const res = await ipcRenderer.invoke('reinstall-helper-bundle');
    if (res.success) {
        showSuccessToast({
            id: 'settings',
            description: res.message
        });
    } else {
        showErrorToast({
            id: 'settings',
            description: res.message
        });
    }
};

export const syncInvokeIpc = async (event: string, data: any = null): Promise<any> => {
    return new Promise((resolve, reject) => {
        ipcRenderer.invoke(event, data).then(resolve).catch(reject);
    });
};

export const openFullDiskPrefs = async () => {
    return await ipcRenderer.invoke('open-fulldisk-preferences');
};

export const openAccessibilityPrefs = async () => {
    return await ipcRenderer.invoke('open-accessibility-preferences');
};

export const getPrivateApiStatus = async () => {
    return await ipcRenderer.invoke('get-private-api-status');
};

export const getAttachmentCacheInfo = async () => {
    return await ipcRenderer.invoke('get-attachment-cache-info');
};

export const clearAttachmentCache = async () => {
    return await ipcRenderer.invoke('clear-attachment-caches');
};

export const deleteScheduledMessage = async (id: number) => {
    return await ipcRenderer.invoke('delete-scheduled-message', id);
};

export const deleteScheduledMessages = async () => {
    return await ipcRenderer.invoke('delete-scheduled-messages');
};

export const createScheduledMessage = async (message: ScheduledMessageItem) => {
    return await ipcRenderer.invoke('create-scheduled-message', message);
};

export const getBinaryPath = async () => {
    return await ipcRenderer.invoke('get-binary-path');
};

export const installUpdate = async () => {
    return await ipcRenderer.invoke('install-update');
};

export const getFirebaseOauthUrl = async () => {
    return await ipcRenderer.invoke('get-firebase-oauth-url');
};

export const getContactsOauthUrl = async () => {
    return await ipcRenderer.invoke('get-contacts-oauth-url');
};

export const restartOauthService = async () => {
    return await ipcRenderer.invoke('restart-oauth-service');
};

export const getCurrentPermissions = async () => {
    return await ipcRenderer.invoke('get-current-permissions');
};

export const saveLanUrl = async () => {
    return await ipcRenderer.invoke('save-lan-url');
};

export const registerZrokEmail = async (email: string) => {
    return await ipcRenderer.invoke('register-zrok-email', email);
};

export const setZrokToken = async (token: string) => {
    return await ipcRenderer.invoke('set-zrok-token', token);
};

export const disableZrok = async () => {
    return await ipcRenderer.invoke('disable-zrok');
};
