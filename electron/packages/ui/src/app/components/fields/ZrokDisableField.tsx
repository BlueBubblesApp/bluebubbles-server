import React, { useRef, useState } from 'react';
import {
    FormControl,
    FormLabel,
    FormHelperText,
    Text,
    IconButton,
    Popover,
    PopoverBody,
    PopoverContent,
    PopoverTrigger
} from '@chakra-ui/react';
import { ConfirmationItems, showSuccessToast } from '../../utils/ToastUtils';
import { disableZrok, saveLanUrl } from 'app/utils/IpcUtils';
import { setConfig } from 'app/slices/ConfigSlice';
import { ConfirmationDialog } from '../modals/ConfirmationDialog';
import { store } from 'app/store';
import { MdDesktopAccessDisabled } from 'react-icons/md';


export interface ZrokDisableFieldProps {
    helpText?: string;
}

const confirmationActions: ConfirmationItems = {
    disable: {
        message: (
            'Are you sure you want to disable Zrok? This will unregister your Zrok environment and set your proxy service to LAN URL.'
        ),
        func: async () => {
            await disableZrok();
            await saveLanUrl();
            store.dispatch(setConfig({ name: 'proxy_service', value: 'lan-url' }));
            showSuccessToast({
                id: 'settings',
                duration: 4000,
                description: 'Successfully disabled Zrok! Switching to LAN URL Mode...'
            });
        }
    }
};

export const ZrokDisableField = ({ helpText }: ZrokDisableFieldProps): JSX.Element => {
    const alertRef = useRef(null);
    const [requiresConfirmation, confirm] = useState((): string | null => {
        return null;
    });

    return (
        <FormControl>
            <FormLabel htmlFor='zrok_disable'>Zrok Management</FormLabel>
            <Popover trigger='hover' placement='right'>
                <PopoverTrigger>
                    <IconButton
                        verticalAlign='top'
                        aria-label='Disable Zrok'
                        icon={<MdDesktopAccessDisabled />}
                        onClick={() => confirm('disable')}
                    />
                </PopoverTrigger>
                <PopoverContent width={'auto'}>
                    <PopoverBody>
                        <Text>Disable Your Zrok Environment</Text>
                    </PopoverBody>
                </PopoverContent>
            </Popover>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        If you are having issues with your Zrok environment, you can disable it using this button.
                    </Text>
                )}
            </FormHelperText>

            <ConfirmationDialog
                modalRef={alertRef}
                onClose={() => confirm(null)}
                body={confirmationActions[requiresConfirmation as string]?.message}
                onAccept={() => {
                    confirmationActions[requiresConfirmation as string].func();
                }}
                isOpen={requiresConfirmation !== null}
            />
        </FormControl>
    );
};