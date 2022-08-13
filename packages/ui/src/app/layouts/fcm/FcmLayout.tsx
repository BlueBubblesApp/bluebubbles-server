import React, { useRef, useState } from 'react';
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
    Spacer,
    SimpleGrid,
    Popover,
    PopoverCloseButton,
    PopoverContent,
    PopoverHeader,
    PopoverBody,
    PopoverArrow,
    PopoverTrigger,
    useBoolean,
    Link
} from '@chakra-ui/react';
import { BsChevronDown } from 'react-icons/bs';
import { FiTrash } from 'react-icons/fi';

import { DropZone } from '../../components/DropZone';
import { isValidServerConfig, isValidClientConfig, isValidFirebaseUrl } from '../../utils/FcmUtils';
import { ErrorDialog, ErrorItem } from '../../components/modals/ErrorDialog';
import { ConfirmationDialog } from '../../components/modals/ConfirmationDialog';
import { hasKey, readFile } from '../../utils/GenericUtils';
import { clearFcmConfiguration, saveFcmClient, saveFcmServer } from '../../actions/FcmActions';
import { setConfig } from '../../slices/ConfigSlice';
import { AiOutlineInfoCircle } from 'react-icons/ai';
import { baseTheme } from '../../../theme';
import { useAppDispatch, useAppSelector } from '../../hooks';


let dragCounter = 0;

export const FcmLayout = (): JSX.Element => {
    const dispatch = useAppDispatch();
    const alertRef = useRef(null);
    const confirmationActions: NodeJS.Dict<any> = {
        clearConfiguration: {
            message: (
                'Are you sure you want to clear your FCM Configuration?<br /><br />' +
                'Doing so will prevent notifications from being delivered until ' +
                'your configuration is re-loaded'
            ),
            func: async () => {
                const success = await clearFcmConfiguration();
                if (success) {
                    dispatch(setConfig({ name: 'fcm_client', 'value': null }));
                    dispatch(setConfig({ name: 'fcm_server', 'value': null }));
                }
            }
        }
    };

    const serverLoaded = (useAppSelector(state => state.config.fcm_server !== null) ?? false);
    const clientLoaded = (useAppSelector(state => state.config.fcm_client !== null) ?? false);
    const [isDragging, setDragging] = useBoolean();
    const [errors, setErrors] = useState([] as Array<ErrorItem>);
    const [requiresConfirmation, setRequiresConfirmation] = useState(null as string | null);
    const alertOpen = errors.length > 0;
    

    const onDrop = async (e: React.DragEvent<HTMLDivElement>) => {
        e.preventDefault();

        dragCounter = 0;
        setDragging.off();
        
        // I'm not sure why, but we need to copy the file data _before_ we read it using the file reader.
        // If we do not, the data transfer file list gets set to empty after reading the first file.
        const listCopy: Array<Blob> = [];
        for (let i = 0; i < e.dataTransfer.files.length; i++) {
            listCopy.push(e.dataTransfer.files.item(i) as Blob);
        }

        // Actually read the files
        const errors: Array<ErrorItem> = [];
        for (let i = 0; i < listCopy.length; i++) {
            try {
                const fileStr = await readFile(listCopy[i]);
                const validClient = isValidClientConfig(fileStr);
                const validServer = isValidServerConfig(fileStr);
                const jsonData = JSON.parse(fileStr);

                if (validClient) {
                    const test = isValidFirebaseUrl(jsonData);
                    if (test) {
                        await saveFcmClient(jsonData);
                        dispatch(setConfig({ name: 'fcm_client', 'value': jsonData }));
                    } else {
                        throw new Error(
                            'Your Firebase setup does not have a real-time database enabled. ' +
                            'Please enable the real-time database in your Firebase Console.'
                        );
                    }
                } else if (validServer) {
                    await saveFcmServer(jsonData);
                    dispatch(setConfig({ name: 'fcm_server', 'value': jsonData }));
                } else {
                    throw new Error('Invalid Google FCM File!');
                }
            } catch (ex: any) {
                errors.push({ id: String(i), message: ex?.message ?? String(ex) });
            }
        }

        if (errors.length > 0) {
            setErrors(errors);
        }
    };

    const onDragEnter = (e: React.DragEvent<HTMLDivElement>) => {
        e.preventDefault();
        if (dragCounter === 0) {
            setDragging.on();
        }

        dragCounter += 1;
    };

    const onDragOver = (e: React.DragEvent<HTMLDivElement>) => {
        e.stopPropagation();
        e.preventDefault();
    };

    const onDragLeave = () => {
        dragCounter -= 1;
        if (dragCounter === 0) {
            setDragging.off();
        }
    };

    const closeAlert = () => {
        setErrors([]);
    };

    const confirm = (confirmationType: string | null) => {
        setRequiresConfirmation(confirmationType);
    };

    return (
        <Box
            p={3}
            borderRadius={10}
            onDragEnter={(e) => onDragEnter(e)}
            onDragLeave={() => onDragLeave()}
            onDragOver={(e) => onDragOver(e)}
            onDrop={(e) => onDrop(e)}
        >
            <Stack direction='column' p={5}>
                <Text fontSize='2xl'>Controls</Text>
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
                            <MenuItem icon={<FiTrash />} onClick={() => confirm('clearConfiguration')}>
                                Clear Configuration
                            </MenuItem>
                        </MenuList>
                    </Menu>
                </Flex>
            </Stack>
            <Stack direction='column' p={5}>
                <Text fontSize='2xl'>Firebase Links</Text>
                <Divider orientation='horizontal' />
                <Spacer />
                <Stack direction='row' mt={3}>
                    <Button
                        size='xs'
                    >
                        <Link
                            href="https://console.firebase.google.com/u/0/project/_/database"
                            target="_blank"
                        >
                            Enable Realtime Database
                        </Link>
                    </Button>
                    <Button
                        size='xs'
                    >
                        <Link
                            href="https://console.firebase.google.com/u/0/project/_/settings/general"
                            target="_blank"
                        >
                            Google Services Download
                        </Link>
                    </Button>
                    <Button
                        size='xs'
                    >
                        <Link
                            href="https://console.firebase.google.com/u/0/project/_/settings/serviceaccounts/adminsdk"
                            target="_blank"
                        >
                            Admin SDK Download
                        </Link>
                    </Button>
                </Stack>
            </Stack>
            <Stack direction='column' p={5}>
                <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                    <Text fontSize='2xl'>Configuration</Text>
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
                                    Drag and drop your JSON configuration files from your Google Firebase Console. If you
                                    do not have these configuration files. Please go to
                                    <span style={{ color: baseTheme.colors.brand.primary }}>
                                        <Link href='https://bluebubbles.app/install' color='brand.primary' target='_blank'> Our Website </Link>
                                    </span>
                                    to learn how.
                                </Text>
                                <Text>
                                    These configurations enable the BlueBubbles server to send notifications and other
                                    messages to all of the clients via Google FCM. Google Play Services is required
                                    for Android Devices.
                                </Text>
                            </PopoverBody>
                        </PopoverContent>
                    </Popover>
                </Flex>
                <Divider orientation='horizontal' />
                <Spacer />

                <SimpleGrid columns={2} spacing={5}>
                    <DropZone
                        text="Drag n' Drop Google Services JSON"
                        loadedText="Google Services JSON Successfully Loaded!"
                        isDragging={isDragging}
                        isLoaded={clientLoaded}
                    />
                    <DropZone
                        text="Drag n' Drop Admin SDK JSON"
                        loadedText="Admin SDK JSON Successfully Loaded!"
                        isDragging={isDragging}
                        isLoaded={serverLoaded}
                    />
                </SimpleGrid>
            </Stack>

            <ErrorDialog
                errors={errors}
                modalRef={alertRef}
                onClose={() => closeAlert()}
                isOpen={alertOpen}
            />

            <ConfirmationDialog
                modalRef={alertRef}
                onClose={() => confirm(null)}
                body={confirmationActions[requiresConfirmation as string]?.message}
                onAccept={() => {
                    if (hasKey(confirmationActions, requiresConfirmation as string)) {
                        confirmationActions[requiresConfirmation as string].func();
                    }
                }}
                isOpen={requiresConfirmation !== null}
            />
        </Box>
    );
};
