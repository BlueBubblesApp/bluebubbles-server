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
                {logs.map(item => (
                    <Tr key={item.id}>
                        <Td wordBreak="break-word">{String(item.message)}</Td>
                        <Td isNumeric>{item.timestamp.toLocaleString()}</Td>
                    </Tr>
                ))}
            </Tbody>
        </Table>
    );
};
