import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';


export interface DockBadgeFieldProps {
    helpText?: string;
}

export const DockBadgeField = ({ helpText }: DockBadgeFieldProps): JSX.Element => {
    const dockBadge: boolean = (useAppSelector(state => state.config.dock_badge) ?? false);

    return (
        <FormControl>
            <Checkbox id='dock_badge' isChecked={dockBadge} onChange={onCheckboxToggle}>Show Dock Badge (Notifications)</Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        Disable this to hide the notifications badge in the dock.
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};