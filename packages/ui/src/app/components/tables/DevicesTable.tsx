import React from 'react';
import {
    Table,
    Thead,
    Tbody,
    Tr,
    Th,
    Td,
    TableCaption
} from '@chakra-ui/react';
import { DeviceItem } from '../../slices/DevicesSlice';


export const DevicesTable = ({ devices }: { devices: Array<DeviceItem> }): JSX.Element => {
    return (
        <Table variant="striped" colorScheme="blue" size='sm'>
            <TableCaption>Devices registered for notifications over Google Play Services</TableCaption>
            <Thead>
                <Tr>
                    <Th>Name</Th>
                    <Th>ID</Th>
                    <Th isNumeric>Last Active</Th>
                </Tr>
            </Thead>
            <Tbody>
                {devices.map(item => (
                    <Tr key={item.name}>
                        <Td wordBreak='break-all'>{item.name}</Td>
                        <Td wordBreak='break-all'>{`${item.id.substring(0, 100)}...`}</Td>
                        <Td isNumeric>{new Date(item.lastActive).toLocaleString()}</Td>
                    </Tr>
                ))}
            </Tbody>
        </Table>
    );
};
