import React, { useEffect, useState } from 'react';
import {
    FormControl,
    FormLabel,
    FormHelperText,
    Input,
    IconButton,
    FormErrorMessage,
    Flex
} from '@chakra-ui/react';
import { useAppDispatch, useAppSelector } from '../../hooks';
import { showSuccessToast } from '../../utils/ToastUtils';
import { setConfig } from '../../slices/ConfigSlice';
import { AiOutlineSave } from 'react-icons/ai';


export interface PollIntervalFieldProps {
    helpText?: string;
}

export const PollIntervalField = ({ helpText }: PollIntervalFieldProps): JSX.Element => {
    const dispatch = useAppDispatch();

    const pollInterval: number = useAppSelector(state => state.config.db_poll_interval) ?? 1000;
    const [newInterval, setNewInterval] = useState(pollInterval);
    const [intervalError, setIntervalError] = useState('');
    const hasIntervalError: boolean = (intervalError?? '').length > 0;

    useEffect(() => { setNewInterval(pollInterval); }, [pollInterval]);

    /**
     * A handler & validator for saving a new poll interval
     *
     * @param theNewInterval - The new interval to save
     */
    const saveInterval = (theNewInterval: number): void => {
        // Validate the interval
        if (theNewInterval < 500) {
            setIntervalError('The interval must be at least 500ms or else database locks can occur');
            return;
        }

        dispatch(setConfig({ name: 'db_poll_interval', value: theNewInterval }));
        if (hasIntervalError) setIntervalError('');
        showSuccessToast({
            id: 'settings',
            duration: 4000,
            description: 'Successfully saved new poll interval! Restarting DB listeners...'
        });
    };

    return (
        <FormControl isInvalid={hasIntervalError}>
            <FormLabel htmlFor='db_poll_interval'>Database Poll Interval (ms)</FormLabel>
            <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                <Input
                    id='db_poll_interval'
                    type='number'
                    maxWidth="5em"
                    value={newInterval}
                    onChange={(e) => {
                        if (hasIntervalError) setIntervalError('');
                        setNewInterval(Number.parseInt(e.target.value));
                    }}
                />
                <IconButton
                    ml={3}
                    verticalAlign='top'
                    aria-label='Save poll interval'
                    icon={<AiOutlineSave />}
                    onClick={() => saveInterval(newInterval)}
                />
            </Flex>
            {!hasIntervalError ? (
                <FormHelperText>
                    {helpText ?? 'Enter how often (in milliseconds) you want the server to check for new messages in the database'}
                </FormHelperText>
            ) : (
                <FormErrorMessage>{intervalError}</FormErrorMessage>
            )}
        </FormControl>
    );
};