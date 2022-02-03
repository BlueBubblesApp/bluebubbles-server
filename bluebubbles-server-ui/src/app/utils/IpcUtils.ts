import { ipcRenderer } from 'electron';
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

export const getDevices = async () => {
    return await ipcRenderer.invoke('get-devices');
};

export const getAlerts = async () => {
    return await ipcRenderer.invoke('get-alerts');
};

export const openLogLocation = async () => {
    return await ipcRenderer.invoke('open-log-location');
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