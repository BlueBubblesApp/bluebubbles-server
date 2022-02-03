import React, { useRef, useState } from 'react';
import { Box, Divider, Flex, Spacer, Stack, Text } from '@chakra-ui/react';
import {
    Menu,
    MenuButton,
    MenuList,
    MenuItem,
    Button,
    Checkbox,
    Popover,
    PopoverCloseButton,
    PopoverContent,
    PopoverHeader,
    PopoverBody,
    PopoverArrow,
    PopoverTrigger
} from '@chakra-ui/react';
import { BsChevronDown, BsBootstrapReboot, BsTerminal } from 'react-icons/bs';
import { VscDebugRestart } from 'react-icons/vsc';
import { AiOutlineClear, AiOutlineInfoCircle } from 'react-icons/ai';
import { FiExternalLink } from 'react-icons/fi';
import { LogsTable } from '../../components/tables/LogsTable';
import { ConfirmationItems } from '../../utils/ToastUtils';
import { ConfirmationDialog } from '../../components/modals/ConfirmationDialog';
import { clearEventCache } from '../../actions/DebugActions';
import { hasKey } from '../../utils/GenericUtils';
import { useAppSelector , useAppDispatch} from '../../hooks';
import { AnyAction } from '@reduxjs/toolkit';
import { clear as clearLogs, setDebug } from '../../slices/LogsSlice';
import { openLogLocation, restartViaTerminal, restartServices, fullRestart } from '../../utils/IpcUtils';


const confirmationActions: ConfirmationItems = {
    clearEventCache: {
        message: (
            'Are you sure you want to clear your event cache?<br /><br />' +
            'Doing so will not necessarily break anything. However, this ' +
            'should only really be used if you are not receiving new message ' +
            'notifications to your device'
        ),
        func: clearEventCache
    },
    restartViaTerminal: {
        message: (
            'Are you sure you want to restart via terminal?<br /><br />' +
            'Doing so will stop the server, close the server, then ' +
            'restart it in a terminal window. ' + 
            'This may help with debugging by allowing you to view the raw server logs.'
        ),
        func: restartViaTerminal
    },
    restartServices: {
        message: (
            'Are you sure you want to restart services?<br /><br />' +
            'This will restart services such as the HTTP service, ' +
            'the Private API service, the proxy services, and more.'
        ),
        func: restartServices
    },
    fullRestart: {
        message: (
            'Are you sure you want to perform a full restart?<br /><br />' +
            'This will close and re-open the BlueBubbles Server'
        ),
        func: fullRestart
    }
};

export const LogsLayout = (): JSX.Element => {
    const dispatch = useAppDispatch();
    const [requiresConfirmation, confirm] = useState((): string | null => {
        return null;
    });
    const alertRef = useRef(null);
    let logs = useAppSelector(state => state.logStore.logs);
    const showDebug = useAppSelector(state => state.logStore.debug);

    // If we don't want to show debug logs, filter them out
    if (!showDebug) {
        logs = logs.filter(e => e.type !== 'debug');
    }

    const toggleDebugMode = (e: React.ChangeEvent<HTMLInputElement>) => {
        dispatch(setDebug(e.target.checked));
    };

    return (
        <Box p={3} borderRadius={10}>
            <Flex flexDirection="column">
                <Stack direction='column' p={5}>
                    <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                        <Text fontSize='2xl'>Controls</Text>
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
                                        This page will allow you to perform debugging actions on your BlueBubbles server.
                                        As many of you know, software is not perfect, and there will always be edge cases
                                        depending on the environment. These controls allow us to get the information needed, or
                                        take the required actions to solve an issue. It also allows you to "see" into what
                                        the server is doing in the background.
                                    </Text>
                                </PopoverBody>
                            </PopoverContent>
                        </Popover>
                    </Flex>
                    <Divider orientation='horizontal' />
                    <Flex flexDirection="row" justifyContent="flex-start">
                        <Menu>
                            <MenuButton
                                as={Button}
                                rightIcon={<BsChevronDown />}
                                width="12em"
                                mr={5}
                            >
                                Manage
                            </MenuButton>
                            <MenuList>
                                <MenuItem icon={<FiExternalLink />} onClick={() => openLogLocation()}>
                                    Open Log Location
                                </MenuItem>
                                <MenuItem icon={<AiOutlineClear />} onClick={() => clearLogs()}>
                                    Clear Logs
                                </MenuItem>
                            </MenuList>
                        </Menu>
                        <Menu>
                            <MenuButton
                                as={Button}
                                rightIcon={<BsChevronDown />}
                                width="12em"
                                mr={5}
                            >
                                Debug Actions
                            </MenuButton>
                            <MenuList>
                                <MenuItem icon={<BsTerminal />} onClick={() => confirm('restartViaTerminal')}>
                                    Restart via Terminal
                                </MenuItem>
                                <MenuItem icon={<VscDebugRestart />} onClick={() => confirm('restartServices')}>
                                    Restart Services
                                </MenuItem>
                                <MenuItem icon={<BsBootstrapReboot />} onClick={() => confirm('fullRestart')}>
                                    Full Restart
                                </MenuItem>
                                <MenuItem icon={<AiOutlineClear />} onClick={() => confirm('clearEventCache')}>
                                    Clear Event Cache
                                </MenuItem>
                            </MenuList>
                        </Menu>
                        
                    </Flex>
                </Stack>
                <Stack direction='column' p={5}>
                    <Text fontSize='2xl'>Debug Logs</Text>
                    <Divider orientation='horizontal' />
                    <Spacer />
                    <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                        <Checkbox onChange={(e) => toggleDebugMode(e)} isChecked={showDebug}>Show Debug Logs</Checkbox>
                        <Popover trigger='hover'>
                            <PopoverTrigger>
                                <Box ml={2} _hover={{ color: 'brand.primary', cursor: 'pointer' }}>
                                    <AiOutlineInfoCircle />
                                </Box>
                            </PopoverTrigger>
                            <PopoverContent>
                                <PopoverArrow />
                                <PopoverCloseButton />
                                <PopoverHeader>Inforamation</PopoverHeader>
                                <PopoverBody>
                                    <Text>
                                        Enabling this option will show DEBUG level logs. Leaving
                                        this disabled will only INFO, WARN, and ERROR level logs.
                                    </Text>
                                </PopoverBody>
                            </PopoverContent>
                        </Popover>
                    </Flex>
                    <Spacer />
                    <LogsTable logs={logs} />
                </Stack>
            </Flex>

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