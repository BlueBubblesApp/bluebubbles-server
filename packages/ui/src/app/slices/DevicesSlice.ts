import { createSlice, PayloadAction } from '@reduxjs/toolkit';
import { clearDevices } from '../utils/IpcUtils';
import { showSuccessToast } from '../utils/ToastUtils';

export interface DeviceItem {
    id: string;
    name: string;
    lastActive: Date;
}

interface DevicesState {
    max: number;
    devices: Array<DeviceItem>;
}

const initialState: DevicesState = {
    max: 25,
    devices: []
};

const deviceExists = (state: DevicesState, device: DeviceItem) => {
    for (const d of state.devices) {
        if (d.id === device.id && d.name === device.name) return true;
    }

    return false;
};


export const DevicesSlice = createSlice({
    name: 'devices',
    initialState,
    reducers: {
        addAll: (state, action: PayloadAction<Array<DeviceItem>>) => {
            for (const i of action.payload) {
                if (deviceExists(state, i)) continue;
                state.devices.push(i);
            }
        },
        add: (state, action: PayloadAction<DeviceItem>) => {
            if (deviceExists(state, action.payload)) return;
            state.devices.push(action.payload);
        },
        clear: (state) => {
            state.devices = [];
            clearDevices().then(() => {
                showSuccessToast({
                    id: 'devices',
                    description: 'Successfully cleared registered devices!'
                });
            });
        }
    }
});

// Action creators are generated for each case reducer function
export const { add, addAll, clear } = DevicesSlice.actions;

export default DevicesSlice.reducer;