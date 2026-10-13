import { createSlice, PayloadAction } from '@reduxjs/toolkit';
import { store } from '../store';
import { MultiSelectValue } from '../types';
import { createWebhook, deleteWebhook, updateWebhook } from '../utils/IpcUtils';
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
                const exists = state.webhooks.find(e => e.url === i.url);
                if (!exists) state.webhooks.push(i);
            }
        },
        create: (state, action: PayloadAction<{ url: string, events: Array<MultiSelectValue> }>) => {
            const exists = state.webhooks.find(e => e.url === action.payload.url);
            if (exists) {
                return showErrorToast({
                    id: 'webhooks',
                    duration: 5000,
                    description: 'A webhook with that URL already exists!'
                });
            }

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
        update: (state, action: PayloadAction<{ id: number, url: string, events: Array<MultiSelectValue> }>) => {
            const existingIndex = state.webhooks.findIndex(e => e.id === action.payload.id);
            if (existingIndex === -1) {
                return showErrorToast({
                    id: 'webhooks',
                    duration: 5000,
                    description: 'Failed to update webhook! Unable to find webhook in database!'
                });
            }

            // Update it in the state
            state.webhooks = state.webhooks.map(e => (e.id === action.payload.id) ?
                { ...e, url: action.payload.url, events: JSON.stringify(action.payload.events.map(i => {
                    return i.value;
                })) } : e);

            // Send the update to the backend
            updateWebhook({
                id: action.payload.id,
                url: action.payload.url,
                events: action.payload.events
            }).then(() => {
                showSuccessToast({
                    id: 'webhooks',
                    description: 'Successfully updated webhook!'
                });
            }).catch(e => {
                showErrorToast({
                    id: 'webhooks',
                    duration: 5000,
                    description: `Failed to update webhook! Error: ${e}`
                });
            });
        },
        remove: (state, action: PayloadAction<number>) => {
            const existingIndex = state.webhooks.findIndex(e => e.id === action.payload);
            if (existingIndex === -1) {
                return showErrorToast({
                    id: 'webhooks',
                    duration: 5000,
                    description: 'The webhook you are trying to remove does not exist!'
                });
            }
    
            state.webhooks.splice(existingIndex, 1);
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
export const { create, remove, update, addAll } = WebhooksSlice.actions;

export default WebhooksSlice.reducer;