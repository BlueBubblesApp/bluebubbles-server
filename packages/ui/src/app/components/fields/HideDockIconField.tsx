import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';


export interface HideDockIconFieldProps {
    helpText?: string;
}

export const HideDockIconField = ({ helpText }: HideDockIconFieldProps): JSX.Element => {
    const hideDockIcon: boolean = (useAppSelector(state => state.config.hide_dock_icon) ?? false);

    return (
        <FormControl>
            <Checkbox id='hide_dock_icon' isChecked={hideDockIcon} onChange={onCheckboxToggle}>Hide Dock Icon</Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        Hiding the dock icon will not close the app. You can open the app again via the status bar icon.
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};