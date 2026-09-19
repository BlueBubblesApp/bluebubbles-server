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
import { BiErrorAlt } from 'react-icons/bi';
import { AiOutlineWarning, AiOutlineInfoCircle } from 'react-icons/ai';
import { BsCheckAll } from 'react-icons/bs';
import { NotificationItem } from '../../slices/NotificationsSlice';
import { IconType } from 'react-icons';

const AlertTypeIcon: NodeJS.Dict<IconType> = {
    warn: AiOutlineWarning,
    info: AiOutlineInfoCircle,
    error: BiErrorAlt
};

export const NotificationsTable = ({ notifications }: { notifications: Array<NotificationItem> }): JSX.Element => {
    return (
        <Table variant="striped" colorScheme="blue" size="md">
            <TableCaption>
                Alerts are normal to have. As long as the server recovers,
                you have nothing to worry about. Alerts are mostly helpful when you
                are experiencing an issue and want to see if any errors have occured.
            </TableCaption>
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
                        <Td verticalAlign='baseline'>
                            <Icon
                                ml={2}
                                fontSize="24"
                                as={AlertTypeIcon[item.type] ?? AiOutlineWarning}
                            />
                        </Td>
                        <Td verticalAlign='baseline'>{item.message}</Td>
                        <Td isNumeric verticalAlign='baseline'>
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
