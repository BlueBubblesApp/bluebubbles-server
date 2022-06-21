import React, { useRef, useState } from 'react';
import {
    Table,
    Thead,
    Tbody,
    Tr,
    Th,
    Td,
    Badge,
    useBoolean,
    Icon,
    Box,
    Tooltip
} from '@chakra-ui/react';
import { AiOutlineEdit } from 'react-icons/ai';
import { MdOutlineEditOff } from 'react-icons/md';
import { ContactDialog } from '../modals/ContactDialog';
import { ImageFromData } from '../ImageFromData';


export interface ContactAddress {
    address: string;
    id?: number;
};

export interface ContactItem {
    phoneNumbers: ContactAddress[];
    emails: ContactAddress[];
    firstName: string;
    lastName: string;
    displayName: string;
    birthday: string;
    avatar: string;
    id: string;
    sourceType: string;
}


export const ContactsTable = ({
    contacts,
    onCreate,
    onDelete,
    onUpdate,
    onAddressAdd,
    onAddressDelete
}: {
    contacts: Array<ContactItem>,
    onCreate?: (contact: ContactItem) => void,
    onDelete?: (contactId: number | string) => void,
    onUpdate?: (contact: Partial<ContactItem>) => void,
    onAddressAdd?: (contactId: number | string, address: string) => void;
    onAddressDelete?: (contactAddressId: number) => void;
}): JSX.Element => {
    const dialogRef = useRef(null);
    const [dialogOpen, setDialogOpen] = useBoolean();
    const [selectedContact, setSelectedContact] = useState(null as any | null);

    return (
        <Box>
            <Table variant="striped" colorScheme="blue" size='sm'>
                <Thead>
                    <Tr>
                        <Th>Edit</Th>
                        <Th>Avatar</Th>
                        <Th>Display Name</Th>
                        <Th isNumeric>Addresses</Th>
                    </Tr>
                </Thead>
                <Tbody>
                    {contacts.map(item => {
                        const name = (item.displayName && item.displayName.length > 0)
                            ? item.displayName
                            : [item?.firstName, item?.lastName].filter((e) => e && e.length > 0).join(' ');
                        const addresses = [
                            ...(item.phoneNumbers ?? []).map(e => e.address),
                            ...(item.emails ?? []).map(e => e.address)
                        ];
                        return (
                            <Tr key={`${item.sourceType}-${item.id}-${name}-${addresses.join('_')}`}>
                                <Td _hover={{ cursor: (item?.sourceType === 'api') ? 'auto' : 'pointer' }} onClick={() => {
                                    if (item?.sourceType === 'api') return;
                                    setSelectedContact(item);
                                    setDialogOpen.on();
                                }}>
                                    {(item?.sourceType === 'api') ? (
                                        <Tooltip label="Not Editable" hasArrow aria-label='not editable tooltip'>
                                            <span>
                                                <Icon as={MdOutlineEditOff} />
                                            </span>
                                        </Tooltip>
                                    ): (
                                        <Tooltip label="Click to Edit" hasArrow aria-label='editable tooltip'>
                                            <span>
                                                <Icon as={AiOutlineEdit} />
                                            </span>
                                        </Tooltip>
                                    )}
                                </Td>
                                <Td>
                                    <Box ml={3}>
                                        {(item?.avatar && item.avatar.length > 0) ? (
                                            <ImageFromData data={item.avatar} height={24} width={24} style={{ borderRadius: 24 }} />
                                        ) : (
                                            <Badge>N/A</Badge>
                                        )}
                                    </Box>
                                </Td>
                                <Td>{name}</Td>
                                <Td isNumeric>{addresses.map((addr) => (
                                    <Badge ml={2} key={`${name}-${addr}-${addresses.length}`}>{addr}</Badge>
                                ))}</Td>
                            </Tr>
                        );
                    })}
                </Tbody>
            </Table>

            <ContactDialog
                modalRef={dialogRef}
                isOpen={dialogOpen}
                existingContact={selectedContact}
                onDelete={onDelete}
                onCreate={onCreate}
                onUpdate={onUpdate}
                onAddressAdd={onAddressAdd}
                onAddressDelete={onAddressDelete}
                onClose={() => {
                    setSelectedContact(null);
                    setDialogOpen.off();
                }}
            />
        </Box>
    );
};
