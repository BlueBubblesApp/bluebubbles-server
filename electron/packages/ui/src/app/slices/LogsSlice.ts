import { createSlice, PayloadAction } from '@reduxjs/toolkit';
import { showSuccessToast } from '../utils/ToastUtils';

export interface LogItem {
    id: string;
    message: string;
    type: string;
    timestamp: Date;
}

interface LogsState {
    max: number;
    logs: Array<LogItem>;
    debug: boolean;
    messagesAppLogs: boolean;
}

const initialState: LogsState = {
    max: 100,
    logs: [],
    debug: false,
    messagesAppLogs: false
};

export const LogsSlice = createSlice({
    name: 'logs',
    initialState,
    reducers: {
        add: (state, action: PayloadAction<LogItem>) => {
            // Skip over any debug logs if they aren't enabled
            if (!state.debug && action.payload.type === 'debug') return;
            state.logs.push(action.payload);
            state.logs.sort((a, b) => a.timestamp > b.timestamp ? -1 : 1);
            state.logs = state.logs.slice(0, state.max);
        },
        prune: (state) => {
            state.logs = state.logs.slice(0, state.max);
        },
        setDebug: (state, action: PayloadAction<boolean>) => {
            state.debug = action.payload;
        },
        setMessagesAppLogs: (state, action: PayloadAction<boolean>) => {
            state.messagesAppLogs = action.payload;
        },
        filter: (state, action: PayloadAction<(item: LogItem) => boolean>) => {
            state.logs = state.logs.filter(action.payload);
        },
        clear: (state) => {
            state.logs = [];
            showSuccessToast({
                id: 'logs',
                description: 'Successfully cleared logs!'
            });
        }
    }
});

// Action creators are generated for each case reducer function
export const { add, prune, setDebug, setMessagesAppLogs, clear, filter } = LogsSlice.actions;

export default LogsSlice.reducer;