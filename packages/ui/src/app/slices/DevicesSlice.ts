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

export const LogsSlice = createSlice({
    name: 'devices',
    initialState,
    reducers: {
        addAll: (state, action: PayloadAction<Array<DeviceItem>>) => {
            for (const i of action.payload) {
                state.devices.push(i);
            }
        },
        add: (state, action: PayloadAction<DeviceItem>) => {
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
export const { add, addAll, clear } = LogsSlice.actions;

export default LogsSlice.reducer;