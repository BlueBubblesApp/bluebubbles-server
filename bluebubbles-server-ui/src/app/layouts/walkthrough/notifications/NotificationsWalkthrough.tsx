import React, { useRef, useState } from 'react';
import {
    Box,
    Text,
    SlideFade,
    Alert,
    AlertIcon,
    Link,
    SimpleGrid,
    useBoolean
} from '@chakra-ui/react';
import { DropZone } from '../../../components/DropZone';
import { useAppDispatch, useAppSelector } from '../../../hooks';
import { ErrorDialog, ErrorItem } from '../../../components/modals/ErrorDialog';
import { readFile } from '../../../utils/GenericUtils';
import { isValidClientConfig, isValidFirebaseUrl, isValidServerConfig } from '../../../utils/FcmUtils';
import { saveFcmClient, saveFcmServer } from '../../../actions/FcmActions';
import { setConfig } from '../../../slices/ConfigSlice';


let dragCounter = 0;

export const NotificationsWalkthrough = (): JSX.Element => {
    const dispatch = useAppDispatch();
    const alertRef = useRef(null);

    const serverLoaded = (useAppSelector(state => state.config.fcm_server !== null) ?? false);
    const clientLoaded = (useAppSelector(state => state.config.fcm_client !== null) ?? false);
    const [isDragging, setDragging] = useBoolean();
    const [errors, setErrors] = useState([] as Array<ErrorItem>);
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

    return (
        <SlideFade in={true} offsetY='150px'>
            <Box
                px={5}
                onDragEnter={(e) => onDragEnter(e)}
                onDragLeave={() => onDragLeave()}
                onDragOver={(e) => onDragOver(e)}
                onDrop={(e) => onDrop(e)}    
            >
                <Text fontSize='4xl'>Notifications &amp; Firebase</Text>
                <Text fontSize='md' mt={5}>
                    BlueBubbles utilizes Google FCM (Firebase Cloud Messaging) to deliver notifications to your devices.
                    We do this so the client do not need to hold a connection to the server at all times. As a result,
                    BlueBubbles can deliver notifications even when the app is running in the background. It also means
                    BlueBubbles will use less battery when running in the background.
                </Text>
                <Alert status='info' mt={5}>
                    <AlertIcon />
                    If you do not complete this setup, you will not receive notifications!
                </Alert>
                <Text fontSize='md' mt={5}>
                    The setup with Google FCM is a bit tedious, but it is a "set it and forget it" feature. Follow the
                    instructions here: <Link
                        as='span'
                        href='https://bluebubbles.app/install/'
                        color='brand.primary'
                        target='_blank'>https://bluebubbles.app/install</Link>
                </Text>
                <Text fontSize='3xl' mt={5}>Firebase Configurations</Text>
                
                <SimpleGrid columns={2} spacing={5} mt={5}>
                    <DropZone
                        text="Drag n' Drop google-services.json"
                        loadedText="google-services.json Successfully Loaded!"
                        isDragging={isDragging}
                        isLoaded={serverLoaded}
                    />
                    <DropZone
                        text="Drag n' Drop *-firebase-adminsdk-*.json"
                        loadedText="*-firebase-adminsdk-*.json Successfully Loaded!"
                        isDragging={isDragging}
                        isLoaded={clientLoaded}
                    />
                </SimpleGrid>
            </Box>

            <ErrorDialog
                errors={errors}
                modalRef={alertRef}
                onClose={() => closeAlert()}
                isOpen={alertOpen}
            />
        </SlideFade>
    );
};