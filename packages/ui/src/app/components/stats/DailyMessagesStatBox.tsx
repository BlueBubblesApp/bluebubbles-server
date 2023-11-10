import React from 'react';
import { UpdatableStatBox } from './index';

export const DailyMessagesStatBox = (
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
            title='Daily Messages'
            statName="daily_messages"
            ipcEvent="get-message-count"
            color="yellow"
            autoUpdate={autoUpdate}
            updateInterval={updateInterval}
            delay={delay}
            pastDays={1}
        />
    );
};