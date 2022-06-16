import React, { useEffect, useState } from 'react';
import {
    FormControl,
    FormLabel,
    FormHelperText,
    Input,
    IconButton,
    FormErrorMessage,
    useBoolean,
    Box,
    Link,
    Text,
    Stack,
    HStack,
    VStack
} from '@chakra-ui/react';
import { useAppDispatch, useAppSelector } from '../../hooks';
import { showSuccessToast } from '../../utils/ToastUtils';
import { setConfig } from '../../slices/ConfigSlice';
import { AiFillEye, AiFillEyeInvisible, AiOutlineSave } from 'react-icons/ai';
import { baseTheme } from '../../../theme';


export interface NgrokAuthUserFieldProps {
    helpText?: string;
}

export const NgrokAuthUserField = ({ helpText }: NgrokAuthUserFieldProps): JSX.Element => {
    const dispatch = useAppDispatch();
    const ngrokUser: string = (useAppSelector(state => state.config.ngrok_user) ?? '');
    const ngrokPassword: string = (useAppSelector(state => state.config.ngrok_password) ?? '');
    const [showNgrokPassword, setShowNgrokPassword] = useBoolean();
    const [newNgrokPassword, setNewNgrokPassword] = useState(ngrokPassword);
    const [ngrokPasswordError, setNgrokPasswordError] = useState('');
    const [newNgrokUser, setNewNgrokUser] = useState(ngrokUser);
    const [ngrokUserError, setNgrokUserError] = useState('');
    const hasNgrokUserError: boolean = (ngrokUserError ?? '').length > 0;

    useEffect(() => { setNewNgrokUser(ngrokUser); }, [ngrokUser]);

    /**
     * A handler & validator for saving a new Ngrok auth token.
     *
     * @param theNewNgrokUser - The new auth token to save
     */
    const saveNgrokUserAndPassword = (theNewNgrokUser: string, theNewNgrokPassword: string): void => {
        theNewNgrokUser = theNewNgrokUser.trim();
        theNewNgrokPassword = theNewNgrokPassword.trim();

        // Validate the user
        if (theNewNgrokUser === ngrokUser) {
            setNgrokUserError('You have not changed the username since your last save!');
            return;
        } else if (theNewNgrokUser.includes(' ')) {
            setNgrokUserError('Invalid Ngrok Auth User! Please check that you have copied it correctly.');
            return;
        }

        // Validate the password
        if (theNewNgrokPassword === ngrokPassword) {
            setNgrokUserError('You have not changed the password since your last save!');
            return;
        } else if (theNewNgrokPassword.includes(' ')) {
            setNgrokUserError('Invalid Ngrok Auth Password! Please check that you have copied it correctly.');
            return;
        }

        dispatch(setConfig({ name: 'ngrok_user', value: theNewNgrokUser }));
        dispatch(setConfig({ name: 'ngrok_password', value: theNewNgrokPassword }));
        setNgrokUserError('');
        setNgrokPasswordError('');
        showSuccessToast({
            id: 'settings',
            duration: 4000,
            description: 'Successfully saved new Ngrok Credentials! Restarting Proxy service...'
        });
    };

    return (
        <FormControl isInvalid={hasNgrokUserError}>
            <FormLabel htmlFor='ngrok_user'>Ngrok Authentication (Very Optional)</FormLabel>
            <HStack>
                <Input
                    id='ngrok_user'
                    type='text'
                    maxWidth="20em"
                    value={newNgrokUser}
                    onChange={(e) => {
                        if (hasNgrokUserError) setNgrokUserError('');
                        setNewNgrokUser(e.target.value);
                    }}
                />
                <Input
                    id='ngrok_password'
                    type={showNgrokPassword ? 'text' : 'password'}
                    maxWidth="20em"
                    value={newNgrokPassword}
                    onChange={(e) => {
                        if (hasNgrokUserError) setNgrokPasswordError('');
                        setNewNgrokPassword(e.target.value);
                    }}
                />
                <IconButton
                    ml={3}
                    verticalAlign='top'
                    aria-label='View Ngrok password'
                    icon={showNgrokPassword ? <AiFillEye /> : <AiFillEyeInvisible />}
                    onClick={() => setShowNgrokPassword.toggle()}
                />
                <IconButton
                    ml={3}
                    verticalAlign='top'
                    aria-label='Save Ngrok password'
                    icon={<AiOutlineSave />}
                    onClick={() => saveNgrokUserAndPassword(newNgrokUser, newNgrokPassword)}
                />
            </HStack>
            {!hasNgrokUserError ? (
                <FormHelperText>
                    {helpText ?? (
                        <Text>
                            This an optional additional security measure to protect your ngrok tunnel/server. This will require authentication
                            to the tunnel before a client is able to connect to your bluebubbles sever.
                        </Text>
                    )}
                </FormHelperText>
            ) : (
                <FormErrorMessage>{ngrokUserError}</FormErrorMessage>
            )}
        </FormControl>
        
    );
};