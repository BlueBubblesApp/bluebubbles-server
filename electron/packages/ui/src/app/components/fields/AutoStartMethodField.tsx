import React from 'react';
import {
    Select,
    Flex,
    FormControl,
    FormLabel,
    FormHelperText,
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onSelectChange } from '../../actions/ConfigActions';


export interface AutoStartMethodFieldProps {
    helpText?: string;
}

export const AutoStartMethodField = ({ helpText }: AutoStartMethodFieldProps): JSX.Element => {
    const autoStartMethod: string = (useAppSelector(state => state.config.auto_start_method) ?? '');
    return (
        <FormControl>
            <FormLabel htmlFor='auto_start_method'>Auto Start Method</FormLabel>
            <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                <Select
                    id='auto_start_method'
                    placeholder='Select Auto Start Method'
                    maxWidth="15em"
                    mr={3}
                    value={autoStartMethod}
                    onChange={(e) => {
                        if (!e.target.value || e.target.value.length === 0) return;
                        onSelectChange(e);
                    }}
                >
                    <option value='unset'>Do Not Auto Start</option>
                    <option value='login-item'>Login Item</option>
                    <option value='launch-agent'>Launch Agent (Crash Persistent)</option>
                </Select>
            </Flex>
            <FormHelperText>
                {helpText ?? (
                    'Select whether you want the BlueBubbles Server to automatically start when you login to your computer. ' +
                    'The "Launch Agent" option will let BlueBubbles restart itself, even after a hard crash. If you try to ' +
                    'switch away from the "Launch Agent" method, the server may automatically close itself.'
                )}
            </FormHelperText>
        </FormControl>
    );
};