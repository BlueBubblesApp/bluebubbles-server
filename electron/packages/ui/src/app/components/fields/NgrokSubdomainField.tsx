import React, { useEffect, useState } from 'react';
import {
    FormControl,
    FormLabel,
    FormHelperText,
    Input,
    IconButton,
    FormErrorMessage,
    Box,
    Link,
    Text
} from '@chakra-ui/react';
import { useAppDispatch, useAppSelector } from '../../hooks';
import { showSuccessToast } from '../../utils/ToastUtils';
import { setConfig } from '../../slices/ConfigSlice';
import { AiOutlineSave } from 'react-icons/ai';
import { baseTheme } from '../../../theme';


export interface NgrokSubdomainFieldProps {
    helpText?: string;
}

export const NgrokSubdomainField = ({ helpText }: NgrokSubdomainFieldProps): JSX.Element => {
    const dispatch = useAppDispatch();
    const ngrokSubdomain: string = (useAppSelector(state => state.config.ngrok_custom_domain) ?? '');
    const [newNgrokSubdomain, setNewNgrokSubdomain] = useState(ngrokSubdomain);
    const [ngrokSubdomainError, setNgrokSubdomainError] = useState('');
    const hasNgrokSubdomainError: boolean = (ngrokSubdomainError ?? '').length > 0;

    useEffect(() => { setNewNgrokSubdomain(ngrokSubdomain); }, [ngrokSubdomain]);

    const setSubdomain = (subdomain: string) => {
        dispatch(setConfig({ name: 'ngrok_custom_domain', value: subdomain }));
        setNgrokSubdomainError('');
        showSuccessToast({
            id: 'settings',
            duration: 4000,
            description: 'Successfully saved new Ngrok Custom Subdomain! Restarting Proxy service...'
        });
    };

    /**
     * A handler & validator for saving a new Ngrok auth token.
     *
     * @param theNewNgrokSubdomain - The new auth token to save
     */
    const saveNgrokSubdomain = (theNewNgrokSubdomain: string): void => {
        theNewNgrokSubdomain = theNewNgrokSubdomain.trim();
        if (theNewNgrokSubdomain.length === 0) {
            return setSubdomain('');
        }

        // Validate the port
        if (theNewNgrokSubdomain === ngrokSubdomain) {
            setNgrokSubdomainError('You have not changed the token since your last save!');
            return;
        } else if (theNewNgrokSubdomain.includes(' ')) {
            setNgrokSubdomainError('Invalid Ngrok Auth Subdomain! Please check that you have copied it correctly.');
            return;
        } else if (!theNewNgrokSubdomain.includes('.')) {
            setNgrokSubdomainError('Please enter the full Ngrok subdomain. For example: "my-subdomain.ngrok-free.app"');
            return;
        } else if (theNewNgrokSubdomain.length === 0) {
            setNgrokSubdomainError('An Ngrok Auth Subdomain is required to use the Ngrok proxy service!');
            return;
        }

        setSubdomain(theNewNgrokSubdomain);
    };

    return (
        <FormControl isInvalid={hasNgrokSubdomainError}>
            <FormLabel htmlFor='ngrok_custom_domain'>Ngrok Custom Domain (Optional)</FormLabel>
            <Input
                id='ngrok_custom_domain'
                type='text'
                maxWidth="20em"
                placeholder="my-subdomain.ngrok-free.app"
                value={newNgrokSubdomain}
                onChange={(e) => {
                    if (hasNgrokSubdomainError) setNgrokSubdomainError('');
                    setNewNgrokSubdomain(e.target.value);
                }}
            />
            <IconButton
                ml={3}
                verticalAlign='top'
                aria-label='Save Ngrok Domain'
                icon={<AiOutlineSave />}
                onClick={() => saveNgrokSubdomain(newNgrokSubdomain)}
            />
            {hasNgrokSubdomainError ? (
                <FormErrorMessage>{ngrokSubdomainError}</FormErrorMessage>
            ) : null}
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        On the Ngrok website, you can reserve a subdomain with Ngrok. This allows
                        your URL to stay static, and never change. This may improve connectivity
                        reliability. To reserve your domain today, go to the following link
                        and create a new subdomain. Then copy and paste it into this field:&nbsp;
                        <Box as='span' color={baseTheme.colors.brand.primary}>
                            <Link href='https://dashboard.ngrok.com/cloud-edge/domains' target='_blank'>ngrok.com</Link>
                        </Box>
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};