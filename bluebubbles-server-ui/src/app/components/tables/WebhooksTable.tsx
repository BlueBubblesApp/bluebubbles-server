import React from 'react';
import {
    Table,
    Thead,
    Tbody,
    Tr,
    Th,
    Td,
    TableCaption,
    Box,
    Icon
} from '@chakra-ui/react';
import { FiTrash } from 'react-icons/fi';
import { remove, WebhookItem } from '../../slices/WebhooksSlice';
import { useAppDispatch } from '../../hooks';


export const WebhooksTable = ({ webhooks }: { webhooks: Array<WebhookItem> }): JSX.Element => {
    const dispatch = useAppDispatch();
    return (
        <Table variant="striped" colorScheme="blue">
            <TableCaption>These are callbacks to receive events from the BlueBubbles Server</TableCaption>
            <Thead>
                <Tr>
                    <Th>URL</Th>
                    <Th isNumeric>Delete</Th>
                </Tr>
            </Thead>
            <Tbody>
                {webhooks.map(item => (
                    <Tr key={item.id}>
                        <Td>{item.url}</Td>
                        <Td isNumeric>
                            <Box _hover={{ cursor: 'pointer' }} onClick={() => dispatch(remove(item.id))}>
                                <Icon as={FiTrash} />
                            </Box>
                        </Td>
                    </Tr>
                ))}
            </Tbody>
        </Table>
    );
};
