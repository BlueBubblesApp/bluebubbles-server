import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';

export interface StartMinimizedFieldProps {
    helpText?: string;
}

export const StartMinimizedField = ({ helpText }: StartMinimizedFieldProps): JSX.Element => {
    const startMinimized: boolean = (useAppSelector(state => state.config.start_minimized) ?? false);

    return (
        <FormControl>
            <Checkbox id='start_minimized' isChecked={startMinimized}  onChange={onCheckboxToggle}>Start Minimized</Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        When enabled, the BlueBubbles Server will be minimized after starting up.
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};

