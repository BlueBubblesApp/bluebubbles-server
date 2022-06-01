import React from 'react';
import { UpdatableStatBox } from './index';

export const TotalMessagesStatBox = (
    {
        autoUpdate = true,
        updateInterval = 60000,
        delay = 0
    }:
    {
        autoUpdate?: boolean,
        updateInterval?: number,
        delay?: number
    }
): JSX.Element => {
    return (
        <UpdatableStatBox
            title='Total Messages'
            statName="total_messages"
            ipcEvent="get-message-count"
            color="teal"
            autoUpdate={autoUpdate}
            updateInterval={updateInterval}
            delay={delay}
        />
    );
};