import React from 'react';
import {
    Select,
    Flex,
    FormControl,

} from '@chakra-ui/react';


export interface TimeframeDropdownFieldProps {
    selectedDays: number;
    onChange?: (days: number) => void;
}

export const TimeframeDropdownField = ({ selectedDays = 30 * 6, onChange }: TimeframeDropdownFieldProps): JSX.Element => {
    return (
        <FormControl width="fit-content">
            <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                <Select
                    maxWidth="16em"
                    mr={3}
                    value={String(selectedDays)}
                    onChange={(e) => {
                        if (onChange) {
                            onChange(Number.parseInt(e.target.value));
                        }
                    }}
                >
                    <option value='0'>All Time</option>
                    <option value='365'>Past Year</option>
                    <option value='180'>Past 6 Months</option>
                    <option value='30'>Past Month</option>
                </Select>
            </Flex>
        </FormControl>
    );
};