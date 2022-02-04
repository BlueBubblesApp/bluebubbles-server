import { createSlice, PayloadAction } from '@reduxjs/toolkit';
import { store } from '../store';
import { MultiSelectValue } from '../types';
import { createWebhook, deleteWebhook } from '../utils/IpcUtils';
import { showErrorToast, showSuccessToast } from '../utils/ToastUtils';

export interface WebhookItem {
    id: number;
    url: string;
    events: string;
    created: Date;
}

interface WebhooksState {
    webhooks: Array<WebhookItem>;
}

const initialState: WebhooksState = {
    webhooks: []
};

export const WebhooksSlice = createSlice({
    name: 'webhooks',
    initialState,
    reducers: {
        addAll: (state, action: PayloadAction<Array<WebhookItem>>) => {
            for (const i of action.payload) {
                console.log('adding');
                console.log(i);
                state.webhooks.push(i);
            }
        },
        create: (state, action: PayloadAction<{ url: string, events: Array<MultiSelectValue> }>) => {
            createWebhook(action.payload).then((e: any) => {
                store.dispatch(addAll([e]));
                showSuccessToast({
                    id: 'webhooks',
                    description: 'Successfully created webhook!'
                });
            }).catch(e => {
                showErrorToast({
                    id: 'webhooks',
                    duration: 5000,
                    description: `Failed to create webhook! Error: ${e}`
                });
            });
        },
        remove: (state, action: PayloadAction<number>) => {
            state.webhooks = state.webhooks.filter((e: WebhookItem) => e.id !== action.payload);
            deleteWebhook({ id: action.payload }).then(() => {
                showSuccessToast({
                    id: 'webhooks',
                    description: 'Successfully deleted webhook!'
                });
            }).catch(e => {
                showErrorToast({
                    id: 'webhooks',
                    duration: 5000,
                    description: `Failed to delete webhook! Error: ${e}`
                });
            });
        }
    }
});

// Action creators are generated for each case reducer function
export const { create, remove, addAll } = WebhooksSlice.actions;

export default WebhooksSlice.reducer;