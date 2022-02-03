import React from 'react';
import ReactDOM from 'react-dom';

import { Provider } from 'react-redux';
import App from './app/App';
import { ChakraProvider, extendTheme, ColorModeScript, localStorageManager } from '@chakra-ui/react';
import { baseTheme } from './theme';
import { store } from './app/store';
import { checkPermissions, getAlerts, getConfig, getDevices, getFcmConfig, getPrivateApiRequirements } from './app/utils/IpcUtils';
import { setConfigBulk, ConfigItem, setConfig } from './app/slices/ConfigSlice';
import { addAll as addAllDevices } from './app/slices/DevicesSlice';
import { DeviceItem } from './app/slices/DevicesSlice';
import { add as addLog } from './app/slices/LogsSlice';
import { add as addAlert, addAll as addAllAlerts, NotificationItem } from './app/slices/NotificationsSlice';
import { ipcRenderer } from 'electron';
import { getRandomInt } from './app/utils/GenericUtils';


const theme = extendTheme(baseTheme);

// Load the configuration from the server
getConfig().then(cfg => {
    if (!cfg) return;

    const items: Array<ConfigItem> = [];
    for (const key of Object.keys(cfg)) {
        items.push({ name: key, value: cfg[key], saveToDb: false });
    }

    store.dispatch(setConfigBulk(items));
});

// Load the FCM config from the server
getFcmConfig().then(cfg => {
    if (!cfg) return;

    const items: Array<ConfigItem> = [
        {
            name: 'fcm_client',
            value: cfg.fcm_client,
            saveToDb: false
        },
        {
            name: 'fcm_server',
            value: cfg.fcm_server,
            saveToDb: false
        }
    ];

    store.dispatch(setConfigBulk(items));
});

// Load the devices from the server
getDevices().then(devices => {
    if (!devices) return;

    const items: Array<DeviceItem> = [];
    for (const item of devices) {
        items.push({ id: item.identifier, name: item.name, lastActive: item.last_active });
    }

    store.dispatch(addAllDevices(items));
});

// Load the alerts from the server
getAlerts().then(alerts => {
    if (!alerts) return;

    const items: Array<NotificationItem> = [];
    for (const item of alerts) {
        items.push({
            id: item?.id,
            message: item.value,
            type: item.type,
            timestamp: item?.created ?? new Date(),
            read: item?.isRead ?? false
        });
    }

    store.dispatch(addAllAlerts(items));
});

// Load private API requirements
getPrivateApiRequirements().then(requirements => {
    if (!requirements) return;
    store.dispatch(setConfig({ name: 'private_api_requirements', value: requirements }));
});

// Check permissions
checkPermissions().then(permissions => {
    if (!permissions) return;
    store.dispatch(setConfig({ name: 'permissions', value: permissions }));
});

ipcRenderer.on('new-log', (_: any, data: any) => {
    store.dispatch(addLog({
        id: String(getRandomInt(999999999)),
        message: data.message,
        type: data.type,
        timestamp: new Date()
    }));
});

ipcRenderer.on('config-update', (_: any, cfg: any) => {
    if (!cfg) return;

    const items: Array<ConfigItem> = [];
    for (const key of Object.keys(cfg)) {
        items.push({ name: key, value: cfg[key], saveToDb: false });
    }

    store.dispatch(setConfigBulk(items));
});

ipcRenderer.on('new-alert', (_: any, alert: any) => {
    if (!alert?.value || !alert?.type) return;

    store.dispatch(addAlert({
        id: alert?.id,
        message: alert.value,
        type: alert.type,
        timestamp: alert?.created ?? new Date(),
        read: alert?.isRead ?? false
    }));
});

ReactDOM.render(
    <React.StrictMode>
        <Provider store={store}>
            <ColorModeScript initialColorMode={theme.config.initialColorMode} />
            <ChakraProvider theme={theme} colorModeManager={localStorageManager}>
                <App />
            </ChakraProvider>
        </Provider>
    </React.StrictMode>,
    document.getElementById('root')
);
