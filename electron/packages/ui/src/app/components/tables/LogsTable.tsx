import React from 'react';
import {
    Table,
    Thead,
    Tbody,
    Tr,
    Th,
    Td,
    TableCaption,
} from '@chakra-ui/react';
import { LogItem } from '../../slices/LogsSlice';


export const LogsTable = ({ logs, caption }: { logs: Array<LogItem>, caption?: string }): JSX.Element => {
    const getLogRow = (item: LogItem) => {
        let textColor = 'auto';
        let textWeight = 'normal';
        if (item.type === 'error') {
            textColor = '#F56565';
            textWeight = '600';
        } else if (item.type === 'warn') {
            textColor = '#ED8936';
            textWeight = '500';
        } else if (item.type === 'debug') {
            textColor = '#4A5568';
        }

        return (
            <Tr key={item.id}>
                <Td wordBreak="break-word" color={textColor} fontWeight={textWeight}>{item.message}</Td>
                <Td isNumeric>{item.timestamp.toLocaleString()}</Td>
            </Tr>
        );
    };

    return (
        <Table variant="striped" colorScheme="blue" size='sm'>
            <TableCaption>{caption ?? 'Logs will stream in as they come in'}</TableCaption>
            <Thead>
                <Tr>
                    <Th>Log</Th>
                    <Th isNumeric>Timestamp</Th>
                </Tr>
            </Thead>
            <Tbody>
                {logs.map(item => getLogRow(item))}
            </Tbody>
        </Table>
    );
};
