import React, { useEffect, useState } from 'react';
import {
    FormControl,
    FormLabel,
    FormHelperText,
    Input,
    IconButton,
    FormErrorMessage,
    Flex
} from '@chakra-ui/react';
import { useAppDispatch, useAppSelector } from '../../hooks';
import { showSuccessToast } from '../../utils/ToastUtils';
import { setConfig } from '../../slices/ConfigSlice';
import { AiOutlineSave } from 'react-icons/ai';


export interface LocalPortFieldProps {
    helpText?: string;
}

export const LocalPortField = ({ helpText }: LocalPortFieldProps): JSX.Element => {
    const dispatch = useAppDispatch();

    const port: number = useAppSelector(state => state.config.socket_port) ?? 1234;
    const [newPort, setNewPort] = useState(port);
    const [portError, setPortError] = useState('');
    const hasPortError: boolean = (portError?? '').length > 0;

    useEffect(() => { setNewPort(port); }, [port]);

    /**
     * A handler & validator for saving a new port.
     *
     * @param theNewPort - The new port to save
     */
    const savePort = (theNewPort: number): void => {
        // Validate the port
        if (theNewPort < 1024 || theNewPort > 65635) {
            setPortError('Port must be between 1,024 and 65,635');
            return;
        } else if (theNewPort === port) {
            setPortError('You have not changed the port since your last save!');
            return;
        }

        dispatch(setConfig({ name: 'socket_port', value: theNewPort }));
        if (hasPortError) setPortError('');
        showSuccessToast({
            id: 'settings',
            duration: 4000,
            description: 'Successfully saved new port! Restarting Proxy & HTTP services...'
        });
    };

    return (
        <FormControl isInvalid={hasPortError}>
            <FormLabel htmlFor='socket_port'>Local Port</FormLabel>
            <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                <Input
                    id='socket_port'
                    type='number'
                    maxWidth="5em"
                    value={newPort}
                    onChange={(e) => {
                        if (hasPortError) setPortError('');
                        setNewPort(Number.parseInt(e.target.value));
                    }}
                />
                <IconButton
                    ml={3}
                    verticalAlign='top'
                    aria-label='Save port'
                    icon={<AiOutlineSave />}
                    onClick={() => savePort(newPort)}
                />
            </Flex>
            {!hasPortError ? (
                <FormHelperText>
                    {helpText ?? 'Enter the local port for the socket server to run on'}
                </FormHelperText>
            ) : (
                <FormErrorMessage>{portError}</FormErrorMessage>
            )}
        </FormControl>
    );
};