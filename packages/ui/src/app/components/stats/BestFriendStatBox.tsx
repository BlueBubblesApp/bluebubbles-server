import React from 'react';

import { getContactName } from 'app/utils/IpcUtils';
import { UpdatableStatBox } from './index';
import { StatValue } from './types';

const contactNameCache: NodeJS.Dict<string> = {};

export const BestFriendStatBox = (
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
    const transform = async (value: any): Promise<StatValue> => {
        let currentTopCount = 0;
        let currentTop: string | null = null;
        let isGroup = false;
        value.forEach((item: any) => {
            if (!currentTop || item.message_count > currentTopCount) {
                const guid = item.chat_guid.replace('iMessage', '').replace(';+;', '').replace(';-;', '');
                currentTopCount = item.message_count;
                isGroup = (item.group_name ?? '').length > 0;
                currentTop = isGroup ? item.group_name : guid;
            }
        });

        // If we don't get a top , return "Unknown"
        if (!currentTop) return 'Unknown';

        // If this is an individual, get their contact info
        if (!isGroup) {
            try {
                if (Object.keys(contactNameCache).includes(currentTop)) {
                    return contactNameCache[currentTop] as string;
                } else {
                    const contact = await getContactName(currentTop);
                    if (contact?.firstName) {
                        contactNameCache[currentTop] = `${contact.firstName} ${contact?.lastName ?? ''}`.trim();
                        return contactNameCache[currentTop] as string;
                    }
                }
            } catch {
                // Don't do anything if we fail. The fallback will be applied
            }
        } else if ((currentTop as string).length === 0) {
            return 'Unnamed Group';
        }

        return currentTop;
    };

    return (
        <UpdatableStatBox
            title='Best Friend'
            statName="best_friend"
            ipcEvent="get-individual-message-counts"
            color="purple"
            transform={transform}
            autoUpdate={autoUpdate}
            updateInterval={updateInterval}
            delay={delay}
        />
    );
};