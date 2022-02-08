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


export interface NgrokRegionFieldProps {
    helpText?: string;
}

export const NgrokRegionField = ({ helpText }: NgrokRegionFieldProps): JSX.Element => {
    const ngrokRegion: string = (useAppSelector(state => state.config.ngrok_region) ?? '');
    return (
        <FormControl>
            <FormLabel htmlFor='ngrok_region'>Ngrok Region</FormLabel>
            <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                <Select
                    id='ngrok_region'
                    placeholder='Select your Ngrok Region'
                    maxWidth="15em"
                    mr={3}
                    value={ngrokRegion}
                    onChange={(e) => {
                        if (!e.target.value || e.target.value.length === 0) return;
                        onSelectChange(e);
                    }}
                >
                    <option value='us'>North America</option>
                    <option value='eu'>Europe</option>
                    <option value='ap'>Asia/Pacific</option>
                    <option value='au'>Australia</option>
                    <option value='sa'>South America</option>
                    <option value='jp'>Japan</option>
                    <option value='in'>India</option>
                </Select>
            </Flex>
            <FormHelperText>
                {helpText ?? 'Select the region closest to you. This will ensure latency is at its lowest when connecting to the server.'}
            </FormHelperText>
        </FormControl>
    );
};