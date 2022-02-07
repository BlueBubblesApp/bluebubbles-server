import React, { useRef, useState } from 'react';
import {
    Divider,
    Stack,
    Text,
    Spacer,
    Button
} from '@chakra-ui/react';
import { toggleTutorialCompleted } from '../../../actions/GeneralActions';
import { ConfirmationDialog } from '../../../components/modals/ConfirmationDialog';
import { ConfirmationItems } from '../../../utils/ToastUtils';

const confirmationActions: ConfirmationItems = {
    resetTutorial: {
        message: (
            'Are you sure you want to reset the tutorial?<br /><br />' +
            'You will be locked out of your settings until you re-complete ' +
            'the tutorial steps.'
        ),
        func: () => {
            toggleTutorialCompleted(false);
        }
    }
};


export const ResetSettings = (): JSX.Element => {
    const alertRef = useRef(null);
    const [requiresConfirmation, confirm] = useState((): string | null => {
        return null;
    });
    return (
        <Stack direction='column' p={5}>
            <Text fontSize='2xl'>Reset Settings</Text>
            <Divider orientation='horizontal' />
            <Spacer />
            <Button
                onClick={() => confirm('resetTutorial')}
            >
                Reset Tutorial
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