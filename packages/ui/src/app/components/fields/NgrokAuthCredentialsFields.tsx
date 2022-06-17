import React, { useEffect, useState } from 'react';
import {
    FormControl,
    FormLabel,
    FormHelperText,
    Input,
    IconButton,
    FormErrorMessage,
    useBoolean,
    Text,
    Button,
    Stack,
    HStack,
    Box
} from '@chakra-ui/react';
import { useAppDispatch, useAppSelector } from '../../hooks';
import { showSuccessToast } from '../../utils/ToastUtils';
import { setConfig } from '../../slices/ConfigSlice';
import { AiFillEye, AiFillEyeInvisible, AiOutlineSave } from 'react-icons/ai';
import { baseTheme } from '../../../theme';
import { FaSleigh } from 'react-icons/fa';


export interface NgrokAuthCredentialsFieldsProps {
    helpText?: string;
}

export const NgrokAuthCredentialsFields = ({ helpText }: NgrokAuthCredentialsFieldsProps): JSX.Element => {
    const dispatch = useAppDispatch();
    const ngrokUser: string = (useAppSelector(state => state.config.ngrok_user) ?? '');
    const ngrokPassword: string = (useAppSelector(state => state.config.ngrok_password) ?? '');
    // const ngrokAuthEnabled: boolean = (useAppSelector(state => state.config.ngrok_auth_enabled) ?? false);

    const [showNgrokPassword, setShowNgrokPassword] = useBoolean();
    const [newNgrokPassword, setNewNgrokPassword] = useState(ngrokPassword);
    const [newNgrokUser, setNewNgrokUser] = useState(ngrokUser);
    
    const [ngrokCredentialsError, setNgrokCredentialsError] = useState('');
    
    useEffect(() => { setNewNgrokUser(ngrokUser); }, [ngrokUser]);
    useEffect(() => { setNewNgrokPassword(ngrokPassword); }, [ngrokPassword]);


    /**
     * A handler & validator for saving a new Ngrok auth token.
     *
     * @param theNewNgrokUser - The ngrok username
     * @param theNewNgrokPassword - The ngrok password
     */
    const enableNgrokBasicAuth = (theNewNgrokUser: string, theNewNgrokPassword: string): void => {
        theNewNgrokUser = theNewNgrokUser.trim();
        theNewNgrokPassword = theNewNgrokPassword.trim();

        let errorMsg = '';
        // Validate the user and pass
        if (theNewNgrokUser.length < 4){
            errorMsg = 'Username must be at least 4 characters long.';
        }

        if (theNewNgrokPassword.length < 8){
            errorMsg = errorMsg + ' Password must be at least 8 characters long.';
        }
        if (errorMsg.length > 0) {
            setNgrokCredentialsError(errorMsg);
            return;
        }
        
        setNgrokCredentialsError('');        
        dispatch(setConfig({ name: 'ngrok_auth_enabled', value: true }));
        dispatch(setConfig({ name: 'ngrok_user', value: theNewNgrokUser }));
        dispatch(setConfig({ name: 'ngrok_password', value: theNewNgrokPassword }));
        showSuccessToast({
            id: 'settings',
            duration: 4000,
            description: 'Successfully ENABLED Ngrok Authentication!'
        });
    };

    const disableNgrokBasicAuth = () => {
        setNewNgrokUser('');
        setNewNgrokPassword('');
        setNgrokCredentialsError('');
        dispatch(setConfig({ name: 'ngrok_user', value: '' }));
        dispatch(setConfig({ name: 'ngrok_password', value: '' }));
        dispatch(setConfig({ name: 'ngrok_auth_enabled', value: false}));
        showSuccessToast({
            id: 'settings',
            duration: 4000,
            description: 'Successfully DISABLED Ngrok Authentication'
        });
    };

    return (
        <div>
            <FormControl isInvalid={ngrokCredentialsError != '' ?? true}>
                <FormLabel htmlFor='ngrok_user'>Ngrok Authentication (Very Optional)</FormLabel>
                <HStack>
                    <Box>
                        <Button
                            onClick={() => disableNgrokBasicAuth()}
                        >    
                            Disable
                        </Button>
                    </Box>
                    <Box>
                        <Input
                            id='ngrok_user'
                            placeholder='username'
                            type='text'
                            maxWidth="20em"
                            value={newNgrokUser}
                            onChange={(e) => {
                                if (ngrokCredentialsError == '') setNgrokCredentialsError('');
                                setNewNgrokUser(e.target.value);
                            }}
                        />
                    </Box>
                    <Box>
                        <Input
                            id='ngrok_password'
                            placeholder='password'
                            type={showNgrokPassword ? 'text' : 'password'}
                            maxWidth="20em"
                            value={newNgrokPassword}
                            onChange={(e) => {
                                if (ngrokCredentialsError == '') setNgrokCredentialsError('');
                                setNewNgrokPassword(e.target.value);
                            }}
                        />
                    </Box> 
                    <Box>   
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
                            onClick={() => enableNgrokBasicAuth(newNgrokUser, newNgrokPassword)}
                        />
                    </Box>    
                </HStack>
                { ngrokCredentialsError == '' ? (
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
        </div>
    );
};