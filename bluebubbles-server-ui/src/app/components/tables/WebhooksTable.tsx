import React, { useRef, useState } from 'react';
import {
    Table,
    Thead,
    Tbody,
    Tr,
    Th,
    Td,
    TableCaption,
    Box,
    Icon,
    Grid,
    GridItem,
    Tooltip
} from '@chakra-ui/react';
import { FiTrash } from 'react-icons/fi';
import { AiOutlineEdit } from 'react-icons/ai';
import { remove, WebhookItem } from '../../slices/WebhooksSlice';
import { useAppDispatch } from '../../hooks';
import { webhookEventValueToLabel } from '../../utils/GenericUtils';
import { AddWebhookDialog } from '../modals/AddWebhookDialog';


export const WebhooksTable = ({ webhooks }: { webhooks: Array<WebhookItem> }): JSX.Element => {
    const dispatch = useAppDispatch();
    const dialogRef = useRef(null);
    const [selectedId, setSelectedId] = useState(undefined as number | undefined);
    console.log(selectedId);
    return (
        <Box>
            <Table variant="striped" colorScheme="blue">
                <TableCaption>These are callbacks to receive events from the BlueBubbles Server</TableCaption>
                <Thead>
                    <Tr>
                        <Th>URL</Th>
                        <Th>Events</Th>
                        <Th isNumeric>Actions</Th>
                    </Tr>
                </Thead>
                <Tbody>
                    {webhooks.map(item => (
                        <Tr key={item.id}>
                            <Td>{item.url}</Td>
                            <Td>{JSON.parse(item.events).map((e: string) => webhookEventValueToLabel(e)).join(', ')}</Td>
                            <Td isNumeric>
                                <Grid templateColumns="repeat(2, 1fr)">
                                    <Tooltip label='Edit' placement='bottom'>
                                        <GridItem _hover={{ cursor: 'pointer' }} onClick={() => setSelectedId(item.id)}>
                                            <Icon as={AiOutlineEdit} />
                                        </GridItem>
                                    </Tooltip>
                                    
                                    <Tooltip label='Delete' placement='bottom'>
                                        <GridItem _hover={{ cursor: 'pointer' }} onClick={() => dispatch(remove(item.id))}>
                                            <Icon as={FiTrash} />
                                        </GridItem>
                                    </Tooltip>
                                </Grid>
                            </Td>
                        </Tr>
                    ))}
                </Tbody>
            </Table>

            <AddWebhookDialog
                existingId={selectedId}
                modalRef={dialogRef}
                isOpen={!!selectedId}
                onClose={() => {
                    setSelectedId(undefined);
                }}
            />
        </Box>
    );
};
