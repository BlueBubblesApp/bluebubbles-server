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
    const args = (): NodeJS.Dict<any> | null => {
        const after = new Date();
        after.setDate(after.getDate() - 1);
        return { after };
    };

    return (
        <UpdatableStatBox
            title='Daily Messages'
            statName="daily_messages"
            ipcEvent="get-message-count"
            color="yellow"
            args={args}
            autoUpdate={autoUpdate}
            updateInterval={updateInterval}
            delay={delay}
        />
    );
};