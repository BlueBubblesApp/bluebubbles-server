import { showSuccessToast } from '../utils/ToastUtils';
import { clearEventCache as clearECache } from '../utils/IpcUtils';


export const clearEventCache = (): void => {
    clearECache();
    showSuccessToast({
        id: 'logs',
        description: 'Successfully cleared Event Cache!'
    });
};