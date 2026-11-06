import React, { useEffect, useRef, useState } from 'react';
import {
    Box,
    Divider,
    Flex,
    Stack,
    Text,
    Menu,
    MenuButton,
    MenuList,
    MenuItem,
    Button,
    Popover,
    PopoverCloseButton,
    PopoverContent,
    PopoverHeader,
    PopoverBody,
    PopoverArrow,
    PopoverTrigger,
} from '@chakra-ui/react';
import { BsChevronDown } from 'react-icons/bs';
import { FiTrash } from 'react-icons/fi';
import { BiRefresh } from 'react-icons/bi';
import { store } from '../../store';
import { DevicesTable } from '../../components/tables/DevicesTable';
import { ConfirmationItems, showSuccessToast } from '../../utils/ToastUtils';
import { ConfirmationDialog } from '../../components/modals/ConfirmationDialog';
import { hasKey } from '../../utils/GenericUtils';
import { useAppSelector, useAppDispatch } from '../../hooks';
import { clear, DeviceItem, addAll as addAllDevices } from '../../slices/DevicesSlice';
import { AnyAction } from '@reduxjs/toolkit';
import { AiOutlineInfoCircle } from 'react-icons/ai';
import { getDevices } from '../../utils/IpcUtils';


const confirmationActions: ConfirmationItems = {
    clearDevices: {
        message: (
            'Are you sure you want to clear your registered devices?<br /><br />' +
            'Doing so will mean you will have to re-register your BlueBubbles client ' +
            'by restarting the app.'
        ),
        shouldDispatch: true,
        func: clear as (args?: NodeJS.Dict<any>) => void
    }
};

const refreshDevices = (showToast = true) => {
    getDevices().then(devices => {
        if (!devices) return;
    
        const items: Array<DeviceItem> = [];
        for (const item of devices) {
            items.push({ id: item.identifier, name: item.name, lastActive: item.last_active });
        }
    
        store.dispatch(addAllDevices(items));
    });

    if (showToast) {
        showSuccessToast({ id: 'devices', description: 'Successfully refreshed devices!' });
    }
};

export const DevicesLayout = (): JSX.Element => {
    const [requiresConfirmation, confirm] = useState((): string | null => {
        return null;
    });
    const alertRef = useRef(null);
    const devices = useAppSelector(state => state.deviceStore.devices);
    const dispatch = useAppDispatch();
    
    useEffect(() => {
        refreshDevices(false);

        // Refresh devices every 60 seconds
        const refresher = setInterval(() => {
            refreshDevices(false);
        }, 60000);

        // Return a function to clear the interval on unmount
        return () => clearInterval(refresher);
    }, []);

    return (
        <Box p={3} borderRadius={10}>
            <Stack direction='column' p={5}>
                <Text fontSize='2xl'>Controls</Text>
                <Divider orientation='horizontal' />
                <Box>
                    <Menu>
                        <MenuButton
                            as={Button}
                            rightIcon={<BsChevronDown />}
                            width="12em"mr={5}
                        >
                            Manage
                        </MenuButton>
                        <MenuList>
                            <MenuItem icon={<BiRefresh />} onClick={() => refreshDevices()}>
                                Refresh Devices
                            </MenuItem>
                            <MenuItem icon={<FiTrash />} onClick={() => confirm('clearDevices')}>
                                Clear Devices
                            </MenuItem>
                        </MenuList>
                    </Menu>
                </Box>
            </Stack>
            <Stack direction='column' p={5}>
                <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                    <Text fontSize='2xl'>Android Devices</Text>
                    <Popover trigger='hover'>
                        <PopoverTrigger>
                            <Box ml={2} _hover={{ color: 'brand.primary', cursor: 'pointer' }}>
                                <AiOutlineInfoCircle />
                            </Box>
                        </PopoverTrigger>
                        <PopoverContent>
                            <PopoverArrow />
                            <PopoverCloseButton />
                            <PopoverHeader>Information</PopoverHeader>
                            <PopoverBody>
                                <Text>
                                    Here is where you'll find any devices that are registered with your BlueBubbles
                                    server to receive notifications and other messages. If you do not see your device
                                    here after setting up your app, please contact us for assistance.
                                </Text>
                            </PopoverBody>
                        </PopoverContent>
                    </Popover>
                </Flex>
                <Divider orientation='horizontal' />
                {(devices.length === 0) ? (
                    <Flex justifyContent="center" alignItems="center">
                        <section style={{marginTop: 20}}>
                            <Text fontSize="md">You have no devices registered with the server!</Text>
                        </section>
                    </Flex>
                ) : null}
                {(devices.length > 0) ? (
                    <DevicesTable devices={devices} />
                ) : null}
            </Stack>

            <ConfirmationDialog
                modalRef={alertRef}
                onClose={() => confirm(null)}
                body={confirmationActions[requiresConfirmation as string]?.message}
                onAccept={() => {
                    if (hasKey(confirmationActions, requiresConfirmation as string)) {
                        if (confirmationActions[requiresConfirmation as string].shouldDispatch ?? false) {
                            dispatch(confirmationActions[requiresConfirmation as string].func() as AnyAction);
                        } else {
                            confirmationActions[requiresConfirmation as string].func();
                        }
                    }
                }}
                isOpen={requiresConfirmation !== null}
            />
        </Box>
    );
};