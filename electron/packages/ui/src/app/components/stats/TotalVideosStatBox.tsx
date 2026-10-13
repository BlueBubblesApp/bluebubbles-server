import React from 'react';
import { UpdatableStatBox } from './index';

export const TotalVideosStatBox = (
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
            title='Total Videos'
            statName="total_videos"
            ipcEvent="get-chat-video-count"
            color="green"
            transform={transform}
            autoUpdate={autoUpdate}
            updateInterval={updateInterval}
            delay={delay}
            pastDays={pastDays}
        />
    );
};