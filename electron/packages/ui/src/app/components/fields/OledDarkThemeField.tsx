import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';

export interface UseOledDarkModeFieldProps {
    helpText?: string;
}

export const UseOledDarkModeField = ({ helpText }: UseOledDarkModeFieldProps): JSX.Element => {
    const oledDark: boolean = (useAppSelector(state => state.config.use_oled_dark_mode) ?? false);

    return (
        <FormControl>
            <Checkbox id='use_oled_dark_mode' isChecked={oledDark} onChange={onCheckboxToggle}>Use OLED Black Dark Mode</Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        Enabling this will set the dark mode theme to OLED black
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};

