import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';


export interface StartViaTerminalFieldProps {
    helpText?: string;
}

export const StartViaTerminalField = ({ helpText }: StartViaTerminalFieldProps): JSX.Element => {
    const startViaTerminal: boolean = (useAppSelector(state => state.config.start_via_terminal) ?? false);

    return (
        <FormControl>
            <Checkbox id='start_via_terminal' isChecked={startViaTerminal} onChange={onCheckboxToggle}>Always Start via Terminal</Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        When BlueBubbles starts up, it will auto-reload itself in terminal mode.
                        When in terminal, type "help" for command information.
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};