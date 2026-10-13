import { createSlice, PayloadAction } from '@reduxjs/toolkit';
import { clearAlerts, markAlertsAsRead } from '../actions/NotificationActions';

export interface NotificationItem {
    id: number;
    message: string;
    type: string;
    timestamp: Date;
    read?: boolean;
}

export interface NotificationClearParams {
    showToast?: boolean;
    delete?: boolean;
}

interface NotificationState {
    max: number;
    notifications: Array<NotificationItem>;
}

const initialState: NotificationState = {
    max: 25,
    notifications: []
};

export const NotificationsSlice = createSlice({
    name: 'notifications',
    initialState,
    reducers: {
        add: (state, action: PayloadAction<NotificationItem>) => {
            const exists = state.notifications.find(e => e.id === action.payload.id);
            if (!exists) {
                state.notifications.push(action.payload);
                state.notifications.sort((a, b) => a.timestamp > b.timestamp ? 1 : -1);
                state.notifications = state.notifications.slice(0, state.max);
                state.notifications = state.notifications.reverse();
            }
        },
        addAll: (state, action: PayloadAction<Array<NotificationItem>>) => {
            let added = 0;
            for (const i of action.payload) {
                const exists = state.notifications.find(e => e.id === i.id);
                if (!exists) {
                    state.notifications.push(i);
                    added += 1;
                }
                
            }
            
            if (added > 0) {
                state.notifications.sort((a, b) => a.timestamp > b.timestamp ? 1 : -1);
                state.notifications = state.notifications.slice(0, state.max);
                state.notifications = state.notifications.reverse();
            }
        },
        prune: (state) => {
            state.notifications = state.notifications.slice(0, state.max);
        },
        clear: (state, action: PayloadAction<NotificationClearParams>) => {
            if (action.payload.delete ?? true) {
                clearAlerts(action.payload.showToast ?? true);
            }
            
            state.notifications = [];
        },
        readAll: (state) => {
            const notifications = [...state.notifications];
            const alertIds: Array<number> = [];
            for (const i of notifications) {
                if (!i.read) {
                    i.read = true;
                    alertIds.push(i.id);
                }
            }
    
            markAlertsAsRead(alertIds);
            state.notifications = notifications;
        }
    }
});

// Action creators are generated for each case reducer function
export const { add, prune, readAll, addAll, clear } = NotificationsSlice.actions;

export default NotificationsSlice.reducer;