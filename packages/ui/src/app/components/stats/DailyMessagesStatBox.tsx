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
    const now = new Date();
    const startOfDay = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 0, 0, 0);
    const hoursSinceDayStart = Math.floor((now.getTime() - startOfDay.getTime()) / 3_600_000);
    return (
        <UpdatableStatBox
            title='Messages Today'
            statName="daily_messages"
            ipcEvent="get-message-count"
            color="yellow"
            autoUpdate={autoUpdate}
            updateInterval={updateInterval}
            delay={delay}
            pastHours={hoursSinceDayStart}
        />
    );
};