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
    Text
} from '@chakra-ui/react';
import { useAppDispatch, useAppSelector } from '../../hooks';
import { showSuccessToast } from '../../utils/ToastUtils';
import { setConfig } from '../../slices/ConfigSlice';
import { AiFillEye, AiFillEyeInvisible, AiOutlineSave } from 'react-icons/ai';
import { baseTheme } from '../../../theme';


export interface NgrokAuthTokenFieldProps {
    helpText?: string;
}

export const NgrokAuthTokenField = ({ helpText }: NgrokAuthTokenFieldProps): JSX.Element => {
    const dispatch = useAppDispatch();
    const ngrokToken: string = (useAppSelector(state => state.config.ngrok_key) ?? '');
    const [showNgrokToken, setShowNgrokToken] = useBoolean();
    const [newNgrokToken, setNewNgrokToken] = useState(ngrokToken);
    const [ngrokTokenError, setNgrokTokenError] = useState('');
    const hasNgrokTokenError: boolean = (ngrokTokenError ?? '').length > 0;

    useEffect(() => { setNewNgrokToken(ngrokToken); }, [ngrokToken]);

    /**
     * A handler & validator for saving a new Ngrok auth token.
     *
     * @param theNewNgrokToken - The new auth token to save
     */
    const saveNgrokToken = (theNewNgrokToken: string): void => {
        theNewNgrokToken = theNewNgrokToken.trim();

        // Validate the port
        if (theNewNgrokToken === ngrokToken) {
            setNgrokTokenError('You have not changed the token since your last save!');
            return;
        } else if (theNewNgrokToken.includes(' ')) {
            setNgrokTokenError('Invalid Ngrok Auth Token! Please check that you have copied it correctly.');
            return;
        } else if (theNewNgrokToken.length === 0) {
            setNgrokTokenError('An Ngrok Auth Token is required to use the Ngrok proxy service!');
            return;
        }

        dispatch(setConfig({ name: 'ngrok_key', value: theNewNgrokToken }));
        setNgrokTokenError('');
        showSuccessToast({
            id: 'settings',
            duration: 4000,
            description: 'Successfully saved new Ngrok Auth Token! Restarting Proxy service...'
        });
    };

    return (
        <FormControl isInvalid={hasNgrokTokenError}>
            <FormLabel htmlFor='ngrok_key'>Ngrok Auth Token (Required)</FormLabel>
            <Input
                id='password'
                type={showNgrokToken ? 'text' : 'password'}
                maxWidth="20em"
                value={newNgrokToken}
                onChange={(e) => {
                    if (hasNgrokTokenError) setNgrokTokenError('');
                    setNewNgrokToken(e.target.value);
                }}
            />
            <IconButton
                ml={3}
                verticalAlign='top'
                aria-label='View Ngrok token'
                icon={showNgrokToken ? <AiFillEye /> : <AiFillEyeInvisible />}
                onClick={() => setShowNgrokToken.toggle()}
            />
            <IconButton
                ml={3}
                verticalAlign='top'
                aria-label='Save Ngrok token'
                icon={<AiOutlineSave />}
                onClick={() => saveNgrokToken(newNgrokToken)}
            />
            {!hasNgrokTokenError ? (
                <FormHelperText>
                    {helpText ?? (
                        <Text>
                            Using an Auth Token will allow you to use the benefits of the upgraded Ngrok
                            service. This can improve connection stability and reliability. <b>It is highly
                            recommended that you setup an auth token, especially if you are having connection
                            issues.</b> If you do not have an Ngrok Account, sign up for free here:&nbsp;
                            <Box as='span' color={baseTheme.colors.brand.primary}>
                                <Link href='https://dashboard.ngrok.com/get-started/your-authtoken' target='_blank'>ngrok.com</Link>
                            </Box>
                        </Text>
                    )}
                </FormHelperText>
            ) : (
                <FormErrorMessage>{ngrokTokenError}</FormErrorMessage>
            )}
        </FormControl>
    );
};