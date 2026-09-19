import { ipcRenderer } from 'electron';
import { showSuccessToast } from '../utils/ToastUtils';

export const clearAlerts = async (showToast = true): Promise<void> => {
    await ipcRenderer.invoke('clear-alerts');
    if (showToast) {
        showSuccessToast({
            id: 'alerts',
            description: 'Successfully cleared Alerts!'
        });
    }
};


export const markAlertsAsRead = async (alertIds: Array<number>): Promise<void> => {
    await ipcRenderer.invoke('mark-alerts-as-read', alertIds);
};
