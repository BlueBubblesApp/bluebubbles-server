import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text,
    Code
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';


export interface UseHttpsFieldProps {
    helpText?: string;
}

export const UseHttpsField = ({ helpText }: UseHttpsFieldProps): JSX.Element => {
    const encryption: boolean = (useAppSelector(state => state.config.encrypt_coms) ?? false);

    return (
        <FormControl>
            <Checkbox id='encrypt_coms' isChecked={encryption} onChange={onCheckboxToggle}>Encrypt Messages</Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        This will install a self-signed certificate at: <Code>~/Library/Application Support/bluebubbles-server/Certs</Code>
                        <br />
                        Note: Only use this this option if you have your own certificate! Replace the certificates in the "<Code>Certs</Code>" directory
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};