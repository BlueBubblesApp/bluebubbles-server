import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';

export interface CheckForUpdatesFieldProps {
    helpText?: string;
}

export const CheckForUpdatesField = ({ helpText }: CheckForUpdatesFieldProps): JSX.Element => {
    const checkForUpdates: boolean = (useAppSelector(state => state.config.check_for_updates) ?? false);

    return (
        <FormControl>
            <Checkbox id='check_for_updates' isChecked={checkForUpdates} onChange={onCheckboxToggle}>Check for Updates on Startup</Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        When enabled, BlueBubbles will automatically check for updates on startup
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};

