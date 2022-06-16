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
    Checkbox,
    Stack,
    HStack,
    Spacer,
} from '@chakra-ui/react';
import { useAppDispatch, useAppSelector } from '../../hooks';
import { showSuccessToast } from '../../utils/ToastUtils';
import { setConfig } from '../../slices/ConfigSlice';
import { onCheckboxToggle } from '../../actions/ConfigActions';
import { AiFillEye, AiFillEyeInvisible, AiOutlineSave } from 'react-icons/ai';
import { baseTheme } from '../../../theme';


export interface NgrokAuthUserFieldProps {
    helpText?: string;
}

export const NgrokAuthUserField = ({ helpText }: NgrokAuthUserFieldProps): JSX.Element => {
    const dispatch = useAppDispatch();
    const ngrokUser: string = (useAppSelector(state => state.config.ngrok_user) ?? '');
    const ngrokPassword: string = (useAppSelector(state => state.config.ngrok_password) ?? '');
    const ngrokAuthEnabled: boolean = (useAppSelector(state => state.config.ngrok_auth_enabled) ?? false);

    const [showNgrokPassword, setShowNgrokPassword] = useBoolean();

    const [newNgrokPassword, setNewNgrokPassword] = useState(ngrokPassword);
    const [newNgrokUser, setNewNgrokUser] = useState(ngrokUser);
    
    const [ngrokCredentialsError, setNgrokCredentialsError] = useState('');
    
    const hasNgrokCredentialsError: boolean = (ngrokCredentialsError ?? '').length > 0;

    useEffect(() => { setNewNgrokUser(ngrokUser); }, [ngrokUser]);

    /**
     * A handler & validator for saving a new Ngrok auth token.
     *
     * @param theNewNgrokUser - The new auth token to save
     */
    const saveNgrokUserAndPassword = (theNewNgrokUser: string, theNewNgrokPassword: string): void => {
        theNewNgrokUser = theNewNgrokUser.trim();
        theNewNgrokPassword = theNewNgrokPassword.trim();

        let completeErrorMsg = '';
        // Validate the user
        if (theNewNgrokUser.length < 1) {
            completeErrorMsg = completeErrorMsg + 'Invalid Ngrok Auth User! Please check that you have copied it correctly. ';
        }

        // Validate the password
        if (theNewNgrokPassword.length < 8) {
            completeErrorMsg = completeErrorMsg + 'Invalid Ngrok Auth Password! Must be at least 8 characters.';
        }

        if (completeErrorMsg != '') {
            setNgrokCredentialsError(completeErrorMsg);
            return;
        }
        
        setNgrokCredentialsError('');
        dispatch(setConfig({ name: 'ngrok_user', value: theNewNgrokUser }));
        dispatch(setConfig({ name: 'ngrok_password', value: theNewNgrokPassword }));
        showSuccessToast({
            id: 'settings',
            duration: 4000,
            description: 'Successfully saved new Ngrok Credentials! Restarting Proxy service...'
        });
    };

    return (
        <FormControl isInvalid={hasNgrokCredentialsError}>
            <FormLabel htmlFor='ngrok_user'>Ngrok Authentication (Very Optional)</FormLabel>
            <HStack>
                <Checkbox id='ngrok_auth_enabled' isChecked={ngrokAuthEnabled} onChange={onCheckboxToggle}>
                    Enable Auth
                </Checkbox>
                <Input
                    id='ngrok_user'
                    placeholder='username'
                    type='text'
                    maxWidth="20em"
                    value={newNgrokUser}
                    onChange={(e) => {
                        if (hasNgrokCredentialsError) setNgrokCredentialsError('');
                        setNewNgrokUser(e.target.value);
                    }}
                />
                <Input
                    id='ngrok_password'
                    placeholder='password'
                    type={showNgrokPassword ? 'text' : 'password'}
                    maxWidth="20em"
                    value={newNgrokPassword}
                    onChange={(e) => {
                        if (hasNgrokCredentialsError) setNgrokCredentialsError('');
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
            {!hasNgrokCredentialsError ? (
                <FormHelperText>
                    {helpText ?? (
                        <Text>
                            This an optional additional security measure to protect your ngrok tunnel/server. This will require authentication
                            to the tunnel before a client is able to connect to your bluebubbles sever.
                        </Text>
                    )}
                </FormHelperText>
            ) : (
                <Stack>
                    <FormErrorMessage>{ngrokCredentialsError}</FormErrorMessage>
                </Stack>
                
            )}
        </FormControl>
        
    );
};