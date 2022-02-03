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


export const LogsTable = ({ logs }: { logs: Array<LogItem> }): JSX.Element => {
    return (
        <Table variant="striped" colorScheme="blue">
            <TableCaption>Logs will stream in as they come in</TableCaption>
            <Thead>
                <Tr>
                    <Th>Log</Th>
                    <Th isNumeric>Timestamp</Th>
                </Tr>
            </Thead>
            <Tbody>
                {logs.map(item => (
                    <Tr key={item.id}>
                        <Td>{item.message}</Td>
                        <Td isNumeric>{item.timestamp.toLocaleString()}</Td>
                    </Tr>
                ))}
            </Tbody>
        </Table>
    );
};
