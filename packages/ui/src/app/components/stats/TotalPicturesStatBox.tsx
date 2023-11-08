import React from 'react';
import { UpdatableStatBox } from './index';

export const TotalPicturesStatBox = (
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
        let total = 0;
        value.forEach((item: any) => {
            total += item.media_count ?? 0;
        });

        return total;
    };

    return (
        <UpdatableStatBox
            title='Total Pictures'
            statName="total_pictures"
            ipcEvent="get-chat-image-count"
            color="orange"
            transform={transform}
            autoUpdate={autoUpdate}
            updateInterval={updateInterval}
            delay={delay}
            pastDays={pastDays}
        />
    );
};