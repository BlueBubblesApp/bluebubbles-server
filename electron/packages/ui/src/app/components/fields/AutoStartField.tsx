import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';

export interface AutoStartFieldProps {
    helpText?: string;
}

export const AutoStartField = ({ helpText }: AutoStartFieldProps): JSX.Element => {
    const autoStart: boolean = (useAppSelector(state => state.config.auto_start) ?? false);

    return (
        <FormControl>
            <Checkbox id='auto_start' isChecked={autoStart}  onChange={onCheckboxToggle}>Startup with macOS</Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        When enabled, BlueBubbles will start automatically when you login.
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};

