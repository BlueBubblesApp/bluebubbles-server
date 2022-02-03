import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';

export interface AutoCaffeinateFieldProps {
    helpText?: string;
}

export const AutoCaffeinateField = ({ helpText }: AutoCaffeinateFieldProps): JSX.Element => {
    const keepAwake: boolean = (useAppSelector(state => state.config.auto_caffeinate) ?? false);

    return (
        <FormControl>
            <Checkbox id='auto_caffeinate' isChecked={keepAwake}  onChange={onCheckboxToggle}>Keep macOS Awake</Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        When enabled, you mac will not fall asleep due to inactivity or a screen screen saver.
                        However, your computer lid's close action may override this.
                        Make sure your computer does not go to sleep when the lid is closed.
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};

