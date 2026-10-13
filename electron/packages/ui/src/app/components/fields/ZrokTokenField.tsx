import React, { useEffect, useState } from 'react';
import {
    FormControl,
    FormLabel,
    FormHelperText,
    Input,
    IconButton,
    FormErrorMessage,
    useBoolean,
    Text
} from '@chakra-ui/react';
import { useAppDispatch, useAppSelector } from '../../hooks';
import { showSuccessToast } from '../../utils/ToastUtils';
import { setConfig } from '../../slices/ConfigSlice';
import { AiFillEye, AiFillEyeInvisible, AiOutlineSave } from 'react-icons/ai';


export interface ZrokTokenFieldProps {
    helpText?: string;
}

export const ZrokTokenField = ({ helpText }: ZrokTokenFieldProps): JSX.Element => {
    const dispatch = useAppDispatch();
    const zrokToken: string = (useAppSelector(state => state.config.zrok_token) ?? '');
    const [showZrokToken, setShowZrokToken] = useBoolean();
    const [newZrokToken, setNewZrokToken] = useState(zrokToken);
    const [zrokTokenError, setZrokTokenError] = useState('');
    const hasZrokTokenError: boolean = (zrokTokenError ?? '').length > 0;

    useEffect(() => { setNewZrokToken(zrokToken); }, [zrokToken]);

    /**
     * A handler & validator for saving a new Zrok auth token.
     *
     * @param theNewZrokToken - The new auth token to save
     */
    const saveZrokToken = (theNewZrokToken: string): void => {
        theNewZrokToken = theNewZrokToken.trim();

        // Validate the port
        if (theNewZrokToken.includes(' ')) {
            setZrokTokenError('Invalid Zrok Token! Please check that you have copied it correctly.');
            return;
        } else if (theNewZrokToken.length === 0) {
            setZrokTokenError('An Zrok Token is required to use the Zrok proxy service!');
            return;
        }

        dispatch(setConfig({ name: 'zrok_token', value: theNewZrokToken }));
        setZrokTokenError('');
        showSuccessToast({
            id: 'settings',
            duration: 4000,
            description: 'Successfully saved new Zrok Token! Restarting Proxy service...'
        });
    };

    return (
        <FormControl isInvalid={hasZrokTokenError}>
            <FormLabel htmlFor='zrok_key'>Zrok Token (Required)</FormLabel>
            <Input
                id='password'
                type={showZrokToken ? 'text' : 'password'}
                maxWidth="20em"
                value={newZrokToken}
                onChange={(e) => {
                    if (hasZrokTokenError) setZrokTokenError('');
                    setNewZrokToken(e.target.value);
                }}
            />
            <IconButton
                ml={3}
                verticalAlign='top'
                aria-label='View Zrok token'
                icon={showZrokToken ? <AiFillEye /> : <AiFillEyeInvisible />}
                onClick={() => setShowZrokToken.toggle()}
            />
            <IconButton
                ml={3}
                verticalAlign='top'
                aria-label='Save Zrok token'
                icon={<AiOutlineSave />}
                onClick={() => saveZrokToken(newZrokToken)}
            />
            {!hasZrokTokenError ? (
                <FormHelperText>
                    {helpText ?? (
                        <Text>
                            A Zrok Token is required to use the Zrok proxy service. If you do not have one, you can sign up for a free account within BlueBubbles.
                        </Text>
                    )}
                </FormHelperText>
            ) : (
                <FormErrorMessage>{zrokTokenError}</FormErrorMessage>
            )}
        </FormControl>
    );
};