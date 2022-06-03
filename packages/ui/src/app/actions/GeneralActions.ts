import { ipcRenderer } from 'electron';

export const toggleTutorialCompleted = async (toggle: boolean): Promise<void> => {
    ipcRenderer.invoke('toggle-tutorial', toggle);
};

export const resetApp = async (): Promise<void> => {
    ipcRenderer.invoke('reset-app');
};