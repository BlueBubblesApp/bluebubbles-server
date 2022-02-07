import React from 'react';
import { store } from '../store';
import { setConfig } from '../slices/ConfigSlice';

export const onCheckboxToggle = (e: React.ChangeEvent<HTMLInputElement>) => {
    const state = store.getState().config;
    const targetId = e.target.id;
    if (Object.keys(state).includes(targetId)) {
        store.dispatch(setConfig({ name: targetId, value: e.target.checked }));
    }
};

export const onSelectChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    const state = store.getState().config;
    const targetId = e.target.id;
    if (Object.keys(state).includes(targetId)) {
        store.dispatch(setConfig({ name: targetId, value: e.target.value }));
    }
};

export const onInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const state = store.getState().config;
    const targetId = e.target.id;
    if (Object.keys(state).includes(targetId)) {
        store.dispatch(setConfig({ name: targetId, value: e.target.value }));
    }
};