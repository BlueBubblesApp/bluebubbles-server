import React from 'react';
import {
    Table,
    Thead,
    Tbody,
    Tr,
    Th,
    Td,
    Text,
    Icon,
    Box,
    Tooltip
} from '@chakra-ui/react';
import { AiOutlineCheck } from 'react-icons/ai';
import { MdErrorOutline } from 'react-icons/md';
import { IoIosTimer } from 'react-icons/io';
import { VscDebugStart } from 'react-icons/vsc';
import { IconType } from 'react-icons';
import { BsTrash } from 'react-icons/bs';
import { intervalTypeToLabel } from 'app/constants';


export interface ScheduledMessageItem {
    id: string | null,
    type: string,
    payload: {
        chatGuid: string,
        message: string,
        method: string,
        selectedMessageGuid?: string,
        effectId?: string,
        subject?: string,
        attributedBody?: NodeJS.Dict<any>,
        partIndex?: number
    },
    scheduledFor: number;
    schedule: {
        type: string,
        interval?: number,
        intervalType?: 'hourly' | 'daily' | 'weekly' | 'monthly' | 'yearly'
    },
    error?: string,
    status?: string,
    created?: number,
    sentAt?: number
}

const statusMap: {[key: string]: { icon: IconType, label: string }} = {
    pending: {
        icon: IoIosTimer,
        label: 'Pending'
    },
    'in-progress': {
        icon: VscDebugStart,
        label: 'In Progress'
    },
    error: {
        icon: MdErrorOutline,
        label: 'Error'
    },
    complete: {
        icon: AiOutlineCheck,
        label: 'Complete'
    }
};


export const ScheduledMessagesTable = ({
    messages,
    onDelete
}: {
    messages: Array<ScheduledMessageItem>,
    onDelete?: (contactId: number | string) => void
}): JSX.Element => {
    return (
        <Box>
            <Table variant="striped" colorScheme="blue" size='sm'>
                <Thead>
                    <Tr>
                        <Th alignContent='left'>Status</Th>
                        <Th>Type</Th>
                        <Th>Message</Th>
                        <Th>Scheduled For</Th>
                        <Th>Schedule Type</Th>
                        <Th isNumeric>Delete</Th>
                    </Tr>
                </Thead>
                <Tbody>
                    {messages.map(item => {
                        const icon = statusMap[item.status as string].icon;
                        let label = statusMap[item.status as string]?.label;
                        if (item.error) {
                            label = item.error;
                        } else if (item.status === 'complete' && item.sentAt) {
                            const sentDate = new Date(item.sentAt);
                            label = `Sent at ${sentDate.toLocaleString()}`;
                        }

                        const date = new Date(item.scheduledFor);
                        let freq = '';
                        if (item.schedule.type === 'recurring') {
                            freq = `Every ${item.schedule.interval} ${intervalTypeToLabel[item.schedule.intervalType as string]}`;
                        }

                        const chatText = `Sending to ${item.payload.chatGuid}`;
                        return (
                            <Tr key={item.id}>
                                <Td alignContent='left'>
                                    <Tooltip label={label} hasArrow aria-label={label.toLowerCase()}>
                                        <span>
                                            <Icon ml={5} as={icon} />
                                        </span>
                                    </Tooltip>
                                </Td>
                                <Td>
                                    <Text>{item.type}</Text>
                                </Td>
                                <Td>
                                    <Tooltip label={chatText} hasArrow aria-label={chatText.toLowerCase()}>
                                        <Text>{item.payload.message}</Text>
                                    </Tooltip>
                                </Td>
                                <Td><Text>{date.toLocaleString()}</Text></Td>
                                <Td alignContent='left'>
                                    <Tooltip label={freq} hasArrow aria-label={freq.toLowerCase()}>
                                        <Text>{item.schedule.type === 'once' ? 'one-time' : item.schedule.type}</Text>
                                    </Tooltip>
                                </Td>
                                <Td isNumeric _hover={{ cursor: 'pointer' }} onClick={async () => {
                                    if (onDelete && item.id) {
                                        onDelete(Number.parseInt(item.id));
                                    }
                                }}>
                                    <Tooltip label="Delete" hasArrow aria-label='delete'>
                                        <span>
                                            <Icon as={BsTrash} />
                                        </span>
                                    </Tooltip>
                                </Td>
                            </Tr>
                        );
                    })}
                </Tbody>
            </Table>
        </Box>
    );
};
