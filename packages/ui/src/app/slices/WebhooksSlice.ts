import { createSlice, PayloadAction } from '@reduxjs/toolkit';
import { store } from '../store';
import { MultiSelectValue } from '../types';
import { createWebhook, deleteWebhook, getWebhooks, updateWebhook, WebhookSecurityOptions } from '../utils/IpcUtils';
import { showErrorToast, showSuccessToast } from '../utils/ToastUtils';

export interface WebhookItem extends WebhookSecurityOptions {
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
        setAll: (state, action: PayloadAction<Array<WebhookItem>>) => {
            state.webhooks = action.payload;
        },
        create: (state, action: PayloadAction<{
            url: string,
            events: Array<MultiSelectValue>,
            options: WebhookSecurityOptions
        }>) => {
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
        update: (state, action: PayloadAction<{
            id: number,
            url: string,
            events: Array<MultiSelectValue>,
            options: WebhookSecurityOptions
        }>) => {
            const existingIndex = state.webhooks.findIndex(e => e.id === action.payload.id);
            if (existingIndex === -1) {
                return showErrorToast({
                    id: 'webhooks',
                    duration: 5000,
                    description: 'Failed to update webhook! Unable to find webhook in database!'
                });
            }

            // Update it in the state
            state.webhooks = state.webhooks.map(e => (e.id === action.payload.id) ? {
                ...e,
                ...action.payload.options,
                url: action.payload.url,
                events: JSON.stringify(action.payload.events.map(i => i.value))
            } : e);

            // Send the update to the backend
            updateWebhook({
                id: action.payload.id,
                url: action.payload.url,
                events: action.payload.events,
                options: action.payload.options
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

                // The optimistic update above was rejected, so reload what is actually saved
                getWebhooks().then((items: Array<WebhookItem>) => store.dispatch(setAll(items)));
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
export const { create, remove, update, addAll, setAll } = WebhooksSlice.actions;

export default WebhooksSlice.reducer;