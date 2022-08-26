import React, { useRef, useState } from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text,
    Box,
    Stack,
    Button,
    Link
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';
import { PrivateApiRequirements } from '../PrivateApiRequirements';
import { ConfirmationItems } from '../../utils/ToastUtils';
import { ConfirmationDialog } from '../modals/ConfirmationDialog';
import { reinstallHelperBundle } from '../../utils/IpcUtils';
import { PrivateApiStatus } from '../PrivateApiStatus';

export interface PrivateApiFieldProps {
    helpText?: string;
}

const confirmationActions: ConfirmationItems = {
    reinstall: {
        message: (
            'Are you sure you want to reinstall the Private API helper bundle?<br /><br />' +
            'This will overwrite any existing helper bundle installation.'
        ),
        func: reinstallHelperBundle
    }
};

export const PrivateApiField = ({ helpText }: PrivateApiFieldProps): JSX.Element => {
    const privateApi: boolean = (useAppSelector(state => state.config.enable_private_api) ?? false);
    const alertRef = useRef(null);
    const [requiresConfirmation, confirm] = useState((): string | null => {
        return null;
    });

    return (
        <Box mt={1}>
            <Stack direction='row'>
                <PrivateApiRequirements />
                <PrivateApiStatus />
            </Stack>
            <FormControl mt={5}>
                <Stack direction='row'>
                    <Checkbox
                        id='enable_private_api'
                        isChecked={privateApi}
                        onChange={onCheckboxToggle}
                    >
                        Private API
                    </Checkbox>
                    <Button
                        size='xs'
                        onClick={() => confirm('reinstall')}
                    >
                        Re-install Helper
                    </Button>
                    <Button size='xs'>
                        <Link target="_blank" href="https://docs.bluebubbles.app/private-api/">
                            Private API Setup Docs
                        </Link>
                    </Button>
                </Stack>
                <FormHelperText>
                    {helpText ?? (
                        <Text>
                            If you have set up the Private API features (via MacForge or MySIMBL),
                            enable this option to allow the server to communicate with the iMessage Private API. If you
                            have not done the Private API setup, use the button above to read the documentation.
                        </Text>
                    )}
                </FormHelperText>
            </FormControl>

            <ConfirmationDialog
                modalRef={alertRef}
                onClose={() => confirm(null)}
                body={confirmationActions[requiresConfirmation as string]?.message}
                onAccept={() => {
                    confirmationActions[requiresConfirmation as string].func();
                }}
                isOpen={requiresConfirmation !== null}
            />
        </Box>
    );
};