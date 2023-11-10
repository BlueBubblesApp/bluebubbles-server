import React from 'react';

import { UpdatableStatBox } from './index';

export const BestFriendStatBox = (
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
    return (
        <UpdatableStatBox
            title='Best Friend'
            statName="best_friend"
            ipcEvent="get-best-friend"
            color="purple"
            autoUpdate={autoUpdate}
            updateInterval={updateInterval}
            delay={delay}
            pastDays={pastDays}
        />
    );
};