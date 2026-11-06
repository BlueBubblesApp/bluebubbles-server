import React from 'react';
import { UpdatableStatBox } from './index';

export const TopGroupStatBox = (
    {
        autoUpdate = true,
        updateInterval = 60000,
        delay = 0,
        pastDays = 0
    }:
    {
        autoUpdate?: boolean,
        updateInterval?: number,
        delay?: number,
        pastDays?: number
    }
): JSX.Element => {
    const transform = (value: any): string | number | null => {
        let currentTopCount = 0;
        let currentTop = 'N/A';
        value.forEach((item: any) => {
            if (item.message_count > currentTopCount) {
                currentTopCount = item.message_count;
                currentTop = item.group_name;
            }
        });

        return currentTop;
    };

    return (
        <UpdatableStatBox
            title='Top Group'
            statName="top_group"
            ipcEvent="get-group-message-counts"
            color="pink"
            transform={transform}
            autoUpdate={autoUpdate}
            updateInterval={updateInterval}
            delay={delay}
            pastDays={pastDays}
        />
    );
};