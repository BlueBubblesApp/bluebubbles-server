import React from 'react';
import {
    Table,
    Thead,
    Tbody,
    Tr,
    Th,
    Td,
    TableCaption,
    Badge
} from '@chakra-ui/react';


export interface ContactItem {
    phoneNumbers: {
        address: string;
    }[];
    emails: {
        address: string;
    }[];
    firstName: string;
    lastName: string;
    nickname: string;
    birthday: string;
    avatar: string;
}


export const ContactsTable = ({ contacts }: { contacts: Array<ContactItem> }): JSX.Element => {
    return (
        <Table variant="striped" colorScheme="blue" size='sm'>
            <Thead>
                <Tr>
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
                        <Tr key={`${name}-${addresses.join('_')}`}>
                            <Td>{name}</Td>
                            <Td isNumeric>{addresses.map((addr) => (
                                <Badge ml={2} key={`${name}-${addr}-${addresses.length}`}>{addr}</Badge>
                            ))}</Td>
                        </Tr>
                    );
                })}
            </Tbody>
        </Table>
    );
};
