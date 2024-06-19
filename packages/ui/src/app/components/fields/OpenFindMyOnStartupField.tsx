import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';

export interface OpenFindMyOnStartupFieldProps {
    helpText?: string;
}

export const OpenFindMyOnStartupField = ({ helpText }: OpenFindMyOnStartupFieldProps): JSX.Element => {
    const openFindMyOnStartup: boolean = (useAppSelector(state => state.config.open_findmy_on_startup) ?? false);

    return (
        <FormControl>
            <Checkbox id='open_findmy_on_startup' isChecked={openFindMyOnStartup}  onChange={onCheckboxToggle}>Open FindMy App on Startup</Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        When enabled, BlueBubbles will automatically open, then hide the FindMy app when the server starts.
                        This is to trigger the fetch of locations from the FindMy app so the server can cache them for clients.
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};

