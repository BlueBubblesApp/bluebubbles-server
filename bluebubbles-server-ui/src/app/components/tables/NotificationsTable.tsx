import React from 'react';
import {
    Table,
    Thead,
    Tbody,
    Tr,
    Th,
    Td,
    TableCaption,
    Icon,
    Flex,
    Text
} from '@chakra-ui/react';
import { VscError } from 'react-icons/vsc';
import { AiOutlineWarning, AiOutlineInfoCircle } from 'react-icons/ai';
import { BsCheckAll } from 'react-icons/bs';
import { NotificationItem } from '../../slices/NotificationsSlice';
import { IconType } from 'react-icons';

const AlertTypeIcon: NodeJS.Dict<IconType> = {
    warn: AiOutlineWarning,
    info: AiOutlineInfoCircle,
    error: VscError
};

export const NotificationsTable = ({ notifications }: { notifications: Array<NotificationItem> }): JSX.Element => {
    return (
        <Table variant="striped" colorScheme="blue">
            <TableCaption>Hopefully nothing terrible is happening...</TableCaption>
            <Thead>
                <Tr>
                    <Th>Type</Th>
                    <Th>Notification</Th>
                    <Th isNumeric>Time / Read</Th>
                </Tr>
            </Thead>
            <Tbody>
                {notifications.map(item => (
                    <Tr key={item.id} color={(item?.read ?? false) ? 'gray.400' : 'current'}>
                        <Td>
                            <Icon
                                ml={2}
                                fontSize="24"
                                as={AlertTypeIcon[item.type] ?? AiOutlineWarning}
                            />
                        </Td>
                        <Td>{item.message}</Td>
                        <Td isNumeric>
                            <Flex flexDirection="row" justifyContent='flex-end' alignItems='center'>
                                <Text mr={1}>{item.timestamp.toLocaleString()}</Text>
                                {(item?.read ?? false) ? <BsCheckAll fontSize={24} /> : null}
                            </Flex>
                            
                        </Td>
                    </Tr>
                ))}
            </Tbody>
        </Table>
    );
};
