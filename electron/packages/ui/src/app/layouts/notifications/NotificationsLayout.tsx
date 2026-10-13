import { ipcRenderer } from 'electron';
import React, { useRef, useState, useEffect } from 'react';
import {
    Alert,
    AlertIcon,
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
    Link,
    Tabs,
    Tab,
    TabList,
    TabPanels,
    TabPanel,
    Image,
    Spinner
} from '@chakra-ui/react';
import { BsChevronDown, BsCheckAll } from 'react-icons/bs';
import { FiTrash } from 'react-icons/fi';

import { DropZone } from '../../components/DropZone';
import { LogsTable } from '../../components/tables/LogsTable';
import { isValidServerConfig, isValidClientConfig, isValidFirebaseUrl } from '../../utils/FcmUtils';
import { ErrorDialog, ErrorItem } from '../../components/modals/ErrorDialog';
import { ConfirmationDialog } from '../../components/modals/ConfirmationDialog';
import { hasKey, readFile } from '../../utils/GenericUtils';
import { clearDevices, getFcmConfig, getFirebaseOauthUrl, restartOauthService } from '../../utils/IpcUtils';
import { clearFcmConfiguration, saveFcmClient, saveFcmServer } from '../../actions/FcmActions';
import { ConfigItem, setConfig, setConfigBulk } from '../../slices/ConfigSlice';
import { ProgressStatus } from '../../types';
import { AiOutlineInfoCircle } from 'react-icons/ai';
import { RiErrorWarningLine } from 'react-icons/ri';
import { baseTheme } from '../../../theme';
import { useAppDispatch, useAppSelector } from '../../hooks';
import GoogleIcon from '../../../images/walkthrough/google-icon.png';


let dragCounter = 0;

export const NotificationsLayout = (): JSX.Element => {
    const dispatch = useAppDispatch();
    const alertRef = useRef(null);
    const serverFcm = useAppSelector(state => state.config.fcm_server as Record<string, any>);
    const serverLoaded = (useAppSelector(state => state.config.fcm_server !== null) ?? false);
    const clientLoaded = (useAppSelector(state => state.config.fcm_client !== null) ?? false);
    const [isDragging, setDragging] = useBoolean();
    let logs = useAppSelector(state => state.logStore.logs);
    const [authStatus, setAuthStatus] = useState((serverLoaded && clientLoaded) ? ProgressStatus.COMPLETED : ProgressStatus.NOT_STARTED);
    const [oauthUrl, setOauthUrl] = useState('');
    const [errors, setErrors] = useState([] as Array<ErrorItem>);
    const [requiresConfirmation, setRequiresConfirmation] = useState(null as string | null);
    const [confirmParams, setConfirmParams] = useState({} as Record<string, any>);
    const alertOpen = errors.length > 0;

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
                    setAuthStatus(ProgressStatus.NOT_STARTED);
                }
            }
        },
        overwriteFirebase: {
            message: (
                'It looks like your Firebase project has changed!<br /><br />' +
                'Continuing will automatically clear your registered devices. ' +
                'This is to make sure that your devices are connected to the correct ' +
                'Firebase project. You may need to re-register your devices!'
            ),
            func: async () => {
                // Clear devices if they continue
                await clearDevices();
                dispatch(setConfig({ name: 'fcm_server', 'value': confirmParams.jsonData }));
                await saveFcmServer(confirmParams.jsonData);
            }
        }
    };

    useEffect(() => {
        // Load the FCM config from the server
        getFcmConfig().then((cfg: any) => {
            if (!cfg) return;

            const items: Array<ConfigItem> = [
                {
                    name: 'fcm_client',
                    value: cfg.fcm_client,
                    saveToDb: false
                },
                {
                    name: 'fcm_server',
                    value: cfg.fcm_server,
                    saveToDb: false
                }
            ];

            dispatch(setConfigBulk(items));
            if (!cfg.fcm_client || !cfg.fcm_server) {
                setAuthStatus(ProgressStatus.NOT_STARTED);
            } else {
                setAuthStatus(ProgressStatus.COMPLETED);
            }
        });

        ipcRenderer.removeAllListeners('oauth-status');
        getFirebaseOauthUrl().then(url => setOauthUrl(url));

        ipcRenderer.on('oauth-status', (_: any, data: ProgressStatus) => {
            setAuthStatus(data);
        });
    }, []);

    logs = logs.filter(log => log.message.startsWith('[OauthService]'));

    const needsConfirmation = async (files: Blob[]): Promise<boolean> => {
        if (serverFcm?.project_id == null) return false;

        // Only return true if one of the files is a server config,
        // and the project ID does not match the original.
        for (let i = 0; i < files.length; i++) {
            try {
                const fileStr = await readFile(files[i]);
                const validServer = isValidServerConfig(fileStr);
                const jsonData = JSON.parse(fileStr);

                if (!validServer) continue;

                if (serverFcm.project_id !== jsonData.project_id) {
                    return true;
                }
            } catch (ex: any) {
                errors.push({ id: String(i), message: ex?.message ?? String(ex) });
            }
        }

        return false;
    };

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

        // Check if the project ID has changed
        const mustConfirm = await needsConfirmation(listCopy);

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
                        dispatch(setConfig({ name: 'fcm_client', 'value': jsonData }));
                        await saveFcmClient(jsonData);
                    } else {
                        throw new Error(
                            'Your Firebase setup does not have a real-time database enabled. ' +
                            'Please enable the real-time database in your Firebase Console.'
                        );
                    }
                } else if (validServer && !mustConfirm) {
                    // If we don't need to confirm, invoke save FCM normally
                    dispatch(setConfig({ name: 'fcm_server', 'value': jsonData }));
                    await saveFcmServer(jsonData);
                } else if (validServer && mustConfirm) {
                    // Invoke the confirmation dialog
                    setConfirmParams({ jsonData });
                    confirm('overwriteFirebase');
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

    const getOauthIcon = () => {
        if (authStatus === ProgressStatus.IN_PROGRESS) {
            return <Spinner size='md' speed='0.65s' />;
        } else if (authStatus === ProgressStatus.COMPLETED) {
            return <BsCheckAll size={24} color='green' />;
        }

        return <RiErrorWarningLine size={24} />;
    };

    const getAlertStatus = () => {
        if (authStatus === ProgressStatus.COMPLETED) {
            return (
                <Alert status='success'>
                    <AlertIcon />
                    Firebase notifications are configured!
                </Alert>
            );
        } else {
            return (
                <Alert status='warning'>
                    <AlertIcon />
                    Firebase is not configured! Failing to configure Firebase Notifications will
                    prevent notifications from being delivered to your Android device.
                </Alert>
            );
        }
    };

    return (
        <Box
            p={8}
            borderRadius={10}
            onDragEnter={(e) => onDragEnter(e)}
            onDragLeave={() => onDragLeave()}
            onDragOver={(e) => onDragOver(e)}
            onDrop={(e) => onDrop(e)}
        >
            <Text fontSize='2xl'>Notifications</Text>
            <Divider orientation='horizontal' />
            <Text fontSize='md' mt={5} mb={5}>
                BlueBubbles utilizes Google Firebase to deliver notifications to your devices.
                This includes delivering notifications on Android as well as server URL changes to all clients (Android, Desktop, & Web). 
                <b>
                    &nbsp;Failing to configure this will mean server URL changes will not sync with BlueBubbles clients.
                </b>
            </Text>
            {getAlertStatus()}
            <Tabs mt={2}>
                <TabList>
                    <Tab>Google Login</Tab>
                    <Tab>Manual Setup</Tab>
                </TabList>
                <TabPanels>
                    <TabPanel>
                        <Text fontSize='md'>
                            Using the button below, you can authorize BlueBubbles to manage your Google Cloud Platform account temporarily.
                            This will allow BlueBubbles to automatically create your Firebase project and setup the necessary configurations
                            so your Android device can receive notifications.
                        </Text>
                        <Link
                            href={oauthUrl}
                            target="_blank"
                            _hover={{ textDecoration: 'none' }}
                        >
                            <Stack direction='row' alignItems='center'>
                                <Button
                                    pl={10}
                                    pr={10}
                                    mt={3}
                                    leftIcon={<Image src={GoogleIcon} mr={1} width={5} />}
                                    variant='outline'
                                    onClick={() => {
                                        restartOauthService();
                                    }}
                                >
                                    Continue with Google
                                </Button>
                                <Box pt={3} pl={2}>
                                    {getOauthIcon()}
                                </Box>
                            </Stack>
                        </Link>
                        <Box mt={3} />
                        <LogsTable logs={logs} caption={'Once authenticated, you can monitor the project setup process via these logs.'} />
                    </TabPanel>
                    <TabPanel>
                        <Text fontSize='md'>
                            The manual setup with Google FCM is optional and can allow for a more flexible setup for complex deployments.
                            For instance, you may want to do a manual setup if you have multiple iMessage accounts and want to use
                            the same Google account for notifications. Follow the step by step
                            instructions here: <Link
                                as='span'
                                href='https://docs.bluebubbles.app/server/installation-guides/manual-setup'
                                color='brand.primary'
                                target='_blank'>Manual Setup Docs</Link>
                        </Text>
                        <Stack direction='column' pt={2} pb={5}>
                            <Text fontSize='2xl'>Firebase Links</Text>
                            <Divider orientation='horizontal' />
                            <Spacer />
                            <Stack direction='row' mt={3}>
                                <Button
                                    size='xs'
                                >
                                    <Link
                                        href="https://console.firebase.google.com/u/0/project/_/firestore"
                                        target="_blank"
                                    >
                                        Enable Firestore
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
                        <Stack direction='column' pb={5}>
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
                            <Stack direction='column'>
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
                            <Box mt={3} />
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
                    </TabPanel>
                </TabPanels>
            </Tabs>

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
