import React from 'react';
import {
    Table,
    Thead,
    Tbody,
    Tr,
    Th,
    Td,
    TableCaption,
    IconButton,
    Menu,
    MenuButton,
    MenuList,
    MenuItem,
} from '@chakra-ui/react';
import { DeviceItem, remove } from '../../slices/DevicesSlice';
import { FiMoreVertical, FiTrash2 } from 'react-icons/fi';
import { useAppDispatch } from '../../hooks';
import { deleteDevice } from '../../utils/IpcUtils';
import { showErrorToast, showSuccessToast } from '../../utils/ToastUtils';


export const DevicesTable = ({ devices }: { devices: Array<DeviceItem> }): JSX.Element => {
    const dispatch = useAppDispatch();
    
    const handleDelete = async (name: string, id: string) => {
        try {
            await deleteDevice(name, id);
            dispatch(remove({ name, id }));
            showSuccessToast({
                id: 'devices',
                description: `Successfully deleted device: ${name}`
            });
        } catch (error: any) {
            showErrorToast({
                id: 'devices',
                description: `Failed to delete device: ${name}. Error: ${error?.message ?? String(error)}`
            });
        }
    };

    return (
        <Table variant="striped" colorScheme="blue" size='sm'>
            <TableCaption>Devices registered for notifications over Google Play Services</TableCaption>
            <Thead>
                <Tr>
                    <Th>Name</Th>
                    <Th>ID</Th>
                    <Th textAlign="center">Last Active</Th>
                    <Th width="60px" isNumeric>Actions</Th>
                </Tr>
            </Thead>
            <Tbody>
                {devices.map(item => (
                    <Tr key={item.name}>
                        <Td wordBreak='break-all'>{item.name}</Td>
                        <Td wordBreak='break-all'>{`${item.id.substring(0, 100)}...`}</Td>
                        <Td textAlign="center">{new Date(item.lastActive).toLocaleString()}</Td>
                        <Td isNumeric>
                            <Menu>
                                <MenuButton
                                    as={IconButton}
                                    aria-label='Options'
                                    icon={<FiMoreVertical />}
                                    variant='filled'
                                    size="sm"
                                />
                                <MenuList>
                                    <MenuItem 
                                        icon={<FiTrash2 />} 
                                        onClick={() => handleDelete(item.name, item.id)}
                                    >
                                        Delete
                                    </MenuItem>
                                </MenuList>
                            </Menu>
                        </Td>
                    </Tr>
                ))}
            </Tbody>
        </Table>
    );
};
