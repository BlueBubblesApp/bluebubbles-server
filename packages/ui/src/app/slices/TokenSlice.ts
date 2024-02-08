import { createSlice, PayloadAction } from '@reduxjs/toolkit';
import { clearDevices, deleteToken, updateToken } from '../utils/IpcUtils';
import { showErrorToast, showSuccessToast } from '../utils/ToastUtils';
import { createToken } from '../utils/IpcUtils';
import { store } from 'app/store';


export interface TokenItem {
    name: string,
    password: string,
    expireAt: number,
}

interface TokenState {
    max: number;
    tokens: Array<TokenItem>;
}

const initialState: TokenState = {
    max: 25,
    tokens: []
};

export const TokenSlice = createSlice({
    name: 'tokens',
    initialState,
    reducers: {
        addAll: (state, action: PayloadAction<Array<TokenItem>>) => {
            for (const i of action.payload) {
                const exists = state.tokens.find(e => e.name === i.name);
                if (!exists) state.tokens.push(i);
            }
        },
        create: (state, action: PayloadAction<{ name: string, password: string, expireAt: number }>) => {
            const exists = state.tokens.find(e => e.name === action.payload.name);
            if (exists) {
                return showErrorToast({
                    id: 'tokens',
                    duration: 5000,
                    description: 'A token with that name already exists!'
                });
            }

            createToken(action.payload).then((e: any) => {
                store.dispatch(addAll([e]));
                showSuccessToast({
                    id: 'tokens',
                    description: 'Successfully created token!'
                });
            }).catch(e => {
                showErrorToast({
                    id: 'tokens',
                    duration: 5000,
                    description: `Failed to create token! Error: ${e}`
                });
            });
        },
        clear: (state) => {
            state.tokens = [];
            clearDevices().then(() => {
                showSuccessToast({
                    id: 'tokens',
                    description: 'Successfully cleared registered tokens!'
                });
            });
        },
        update: (state, action: PayloadAction<{
            expireAt: number; name: string, password: string 
        }>) => {
            const existingIndex = state.tokens.findIndex(e => e.name === action.payload.name);
            if (existingIndex === -1) {
                return showErrorToast({
                    id: 'tokens',
                    duration: 5000,
                    description: 'Failed to update token! Unable to find token in database!'
                });
            }

            // Update it in the state
            state.tokens = state.tokens.map(e => (e.name === action.payload.name) ?
                { ...e, name: action.payload.name, expireAt: action.payload.expireAt } : e);

            // Send the update to the backend
            updateToken({
                name: action.payload.name,
                password: action.payload.password,
                expireAt: action.payload.expireAt,
            }).then(() => {
                showSuccessToast({
                    id: 'tokens',
                    description: 'Successfully updated token!'
                });
            }).catch(e => {
                showErrorToast({
                    id: 'tokens',
                    duration: 5000,
                    description: `Failed to update token! Error: ${e}`
                });
            });
        },
        remove: (state, action: PayloadAction<string>) => {
            const existingIndex = state.tokens.findIndex(e => e.name === action.payload);
            if (existingIndex === -1) {
                return showErrorToast({
                    id: 'tokens',
                    duration: 5000,
                    description: 'The token you are trying to remove does not exist!'
                });
            }
    
            state.tokens.splice(existingIndex, 1);
            deleteToken({
                name: action.payload
            }).then(() => {
                showSuccessToast({
                    id: 'tokens',
                    description: 'Successfully deleted token!'
                });
            }).catch(e => {
                showErrorToast({
                    id: 'tokens',
                    duration: 5000,
                    description: `Failed to delete token! Error: ${e}`
                });
            });
        }

    }
});

export const { create, remove, update, addAll } = TokenSlice.actions;
export default TokenSlice.reducer;