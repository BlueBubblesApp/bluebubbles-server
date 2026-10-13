import { createSlice, PayloadAction } from '@reduxjs/toolkit';
import { ipcRenderer } from 'electron';

const initialState: NodeJS.Dict<any> = {};

export type ConfigItem = {
    name: string,
    value: any,
    saveToDb?: boolean
};

export const ConfigSlice = createSlice({
    name: 'config',
    initialState,
    reducers: {
        setConfig: (state, action: PayloadAction<ConfigItem>) => {
            if (action.payload.saveToDb ?? true) {
                ipcRenderer.invoke('set-config', { [action.payload.name]: action.payload.value });
            }

            if (state[action.payload.name] === action.payload.value) return;
            state[action.payload.name] = action.payload.value;
        },
        setConfigBulk: (state, action: PayloadAction<Array<ConfigItem>>) => {
            for (const i of action.payload) {
                // If the config already exists, we should send the update to the backend too.
                // If it's new, it's probably coming _from_ the server, so no need to set it
                if (i.saveToDb ?? true) {
                    ipcRenderer.invoke('set-config', { [i.name]: i.value });
                }

                if (state[i.name] === i.value) continue;
                state[i.name] = i.value;
            }
        }
    }
});

// Action creators are generated for each case reducer function
export const { setConfig, setConfigBulk } = ConfigSlice.actions;

export default ConfigSlice.reducer;