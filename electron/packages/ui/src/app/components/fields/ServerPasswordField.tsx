import React, { useEffect, useState } from 'react';
import {
    FormControl,
    FormLabel,
    FormHelperText,
    Input,
    IconButton,
    FormErrorMessage,
    useBoolean
} from '@chakra-ui/react';
import { useAppDispatch, useAppSelector } from '../../hooks';
import { showSuccessToast } from '../../utils/ToastUtils';
import { setConfig } from '../../slices/ConfigSlice';
import { AiFillEye, AiFillEyeInvisible, AiOutlineSave } from 'react-icons/ai';


export interface ServerPasswordFieldProps {
    helpText?: string;
    errorOnEmpty?: boolean
}

export const ServerPasswordField = ({ helpText, errorOnEmpty = false }: ServerPasswordFieldProps): JSX.Element => {
    const dispatch = useAppDispatch();

    const password: string = (useAppSelector(state => state.config.password) ?? '');
    const [showPassword, setShowPassword] = useBoolean();
    const [newPassword, setNewPassword] = useState(password);
    const [passwordError, setPasswordError] = useState('');
    const hasPasswordError: boolean = (passwordError?? '').length > 0;

    useEffect(() => {
        setNewPassword(password);
    }, [password]);

    useEffect(() => {
        if (errorOnEmpty && password.length === 0) {
            setPasswordError('Enter a password, then click the save button');
        }
    }, []);

    /**
     * A handler & validator for saving a new password.
     *
     * @param theNewPassword - The new password to save
     */
    const savePassword = (theNewPassword: string): void => {
        // Validate the port
        if (theNewPassword.length < 8) {
            setPasswordError('Your password must be at least 8 characters!');
            return;
        } else if (theNewPassword === password) {
            setPasswordError('You have not changed the password since your last save!');
            return;
        }

        dispatch(setConfig({ name: 'password', value: theNewPassword }));
        if (hasPasswordError) setPasswordError('');
        showSuccessToast({
            id: 'settings',
            description: 'Successfully saved new password!'
        });
    };

    return (
        <FormControl isInvalid={hasPasswordError}>
            <FormLabel htmlFor='password'>Server Password</FormLabel>
            <Input
                id='password'
                type={showPassword ? 'text' : 'password'}
                maxWidth="20em"
                value={newPassword}
                onChange={(e) => {
                    if (hasPasswordError) setPasswordError('');
                    setNewPassword(e.target.value);
                }}
            />
            <IconButton
                ml={3}
                verticalAlign='top'
                aria-label='View password'
                icon={showPassword ? <AiFillEye /> : <AiFillEyeInvisible />}
                onClick={() => setShowPassword.toggle()}
            />
            <IconButton
                ml={3}
                verticalAlign='top'
                aria-label='Save password'
                icon={<AiOutlineSave />}
                onClick={() => savePassword(newPassword)}
            />
            {!hasPasswordError ? (
                <FormHelperText>
                    {helpText ?? 'Enter a password to use for clients to authenticate with the server'}
                </FormHelperText>
            ) : (
                <FormErrorMessage>{passwordError}</FormErrorMessage>
            )}
        </FormControl>
    );
};