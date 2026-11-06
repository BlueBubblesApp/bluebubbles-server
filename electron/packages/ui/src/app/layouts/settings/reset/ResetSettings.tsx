import React, { useRef, useState } from 'react';
import {
    Divider,
    Stack,
    Text,
    Spacer,
    Button
} from '@chakra-ui/react';
import { store } from '../../../store';
import { toggleTutorialCompleted, resetApp } from '../../../actions/GeneralActions';
import { ConfirmationDialog } from '../../../components/modals/ConfirmationDialog';
import { ConfirmationItems } from '../../../utils/ToastUtils';
import { clear as clearLogs } from '../../../slices/LogsSlice';

const confirmationActions: ConfirmationItems = {
    resetTutorial: {
        message: (
            'Are you sure you want to reset the tutorial?<br /><br />' +
            'You will be locked out of your settings until you re-complete ' +
            'the tutorial steps.'
        ),
        func: () => {
            toggleTutorialCompleted(false);
            store.dispatch(clearLogs());
        }
    },
    resetApp: {
        message: (
            'Are you sure you want to reset the app?<br /><br />' +
            'This will remove all your configurations & settings. It ' +
            'will also restart the app when complete.'
        ),
        func: resetApp
    }
};


export const ResetSettings = (): JSX.Element => {
    const alertRef = useRef(null);
    const [requiresConfirmation, confirm] = useState((): string | null => {
        return null;
    });
    return (
        <Stack direction='column' p={5}>
            <Text fontSize='2xl'>Danger Zone</Text>
            <Divider orientation='horizontal' />
            <Spacer />
            <Button
                onClick={() => confirm('resetTutorial')}
            >
                Reset Tutorial
            </Button>
            <Button
                colorScheme={'red'}
                onClick={() => confirm('resetApp')}
            >
                Reset App
            </Button>

            <ConfirmationDialog
                modalRef={alertRef}
                onClose={() => confirm(null)}
                body={confirmationActions[requiresConfirmation as string]?.message}
                onAccept={() => {
                    confirmationActions[requiresConfirmation as string].func();
                }}
                isOpen={requiresConfirmation !== null}
            />
        </Stack>
    );
};