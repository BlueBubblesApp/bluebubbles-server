import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';


export interface EncryptCommunicationsFieldProps {
    helpText?: string;
}

export const EncryptCommunicationsField = ({ helpText }: EncryptCommunicationsFieldProps): JSX.Element => {
    const encryption: boolean = (useAppSelector(state => state.config.encrypt_coms) ?? false);

    return (
        <FormControl>
            <Checkbox id='encrypt_coms' isChecked={encryption} onChange={onCheckboxToggle}>Encrypt Messages</Checkbox>
            <FormHelperText>
                {helpText ?? 'Enabling this will add an additional layer of security to the app communications by encrypting messages with a password-based AES-256-bit algorithm'}
            </FormHelperText>
        </FormControl>
    );
};