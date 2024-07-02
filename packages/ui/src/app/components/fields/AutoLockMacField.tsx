import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';

export interface AutoLockMacFieldProps {
    helpText?: string;
}

export const AutoLockMacField = ({ helpText }: AutoLockMacFieldProps): JSX.Element => {
    const autoLock: boolean = (useAppSelector(state => state.config.auto_lock_mac) ?? false);

    return (
        <FormControl>
            <Checkbox id='auto_lock_mac' isChecked={autoLock}  onChange={onCheckboxToggle}>Automatically Lock Mac After Login</Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        When enabled, you mac will be automatically locked when the BlueBubbles Server detects that it has just booted up.
                        The criteria for this is that the uptime for your Mac is less than 5 minutes.
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};

