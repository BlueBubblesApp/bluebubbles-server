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
    Box
} from '@chakra-ui/react';
import { AiOutlineEdit } from 'react-icons/ai';
import { MdOutlineEditOff } from 'react-icons/md';
import { ContactDialog } from '../modals/ContactDialog';


export interface ContactAddress {
    address: string;
    id?: number;
};

export interface ContactItem {
    phoneNumbers: ContactAddress[];
    emails: ContactAddress[];
    firstName: string;
    lastName: string;
    nickname: string;
    birthday: string;
    avatar: string;
    id: string;
    sourceType: string;
}


export const ContactsTable = ({
    contacts,
    onCreate,
    onDelete,
    onAddressAdd,
    onAddressDelete
}: {
    contacts: Array<ContactItem>,
    onCreate?: (contact: ContactItem) => void,
    onDelete?: (contactId: number) => void,
    onAddressAdd?: (contactId: number, address: string) => void;
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
                        <Th>Name</Th>
                        <Th isNumeric>Addresses</Th>
                    </Tr>
                </Thead>
                <Tbody>
                    {contacts.map(item => {
                        const name = (item.nickname && item.nickname.length > 0)
                            ? item.nickname
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
                                        <Icon as={MdOutlineEditOff} />
                                    ): (
                                        <Icon as={AiOutlineEdit} />
                                    )}
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
