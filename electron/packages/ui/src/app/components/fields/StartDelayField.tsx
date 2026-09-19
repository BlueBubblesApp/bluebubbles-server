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


export interface StartDelayFieldProps {
    helpText?: string;
}

export const StartDelayField = ({ helpText }: StartDelayFieldProps): JSX.Element => {
    const dispatch = useAppDispatch();

    const startDelayVal = useAppSelector(state => state.config.start_delay) ?? '0';
    let startDelay = 0;
    if (typeof startDelayVal === 'boolean' && startDelayVal === true) {
        startDelay = 1;
    } else if (typeof startDelayVal === 'boolean' && startDelayVal === false) {
        startDelay = 0;
    } else {
        startDelay = Number.parseInt(startDelayVal);
    }

    const [newStartDelay, setStartDelay] = useState(startDelay);
    const [startDelayError, setDelayError] = useState('');
    const hasDelayError: boolean = (startDelayError?? '').length > 0;

    useEffect(() => { setStartDelay(startDelay); }, [startDelay]);

    /**
     * A handler & validator for saving a new startDelay.
     *
     * @param theNewDelay - The new startDelay to save
     */
    const saveStartDelay = (theNewDelay: number): void => {
        // Validate the startDelay
        if (theNewDelay < 0) {
            setDelayError('Start Delay must be greater than 0');
            return;
        } else if (theNewDelay === startDelay) {
            setDelayError('You have not changed the Start Delay since your last save!');
            return;
        }

        dispatch(setConfig({ name: 'start_delay', value: String(theNewDelay) }));
        if (hasDelayError) setDelayError('');
        showSuccessToast({
            id: 'settings',
            duration: 4000,
            description: 'Successfully saved new Start Delay!'
        });
    };

    return (
        <FormControl isInvalid={hasDelayError}>
            <FormLabel htmlFor='start_delay'>Start Delay (Seconds)</FormLabel>
            <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                <Input
                    id='start_delay'
                    type='number'
                    maxWidth="5em"
                    value={newStartDelay}
                    onChange={(e) => {
                        if (hasDelayError) setDelayError('');
                        setStartDelay(Number.parseInt(e.target.value));
                    }}
                />
                <IconButton
                    ml={3}
                    verticalAlign='top'
                    aria-label='Save Start Delay'
                    icon={<AiOutlineSave />}
                    onClick={() => saveStartDelay(newStartDelay)}
                />
            </Flex>
            {!hasDelayError ? (
                <FormHelperText>
                    {helpText ?? 'Enter the number of seconds to delay the server start by. This is useful on older hardware.'}
                </FormHelperText>
            ) : (
                <FormErrorMessage>{startDelayError}</FormErrorMessage>
            )}
        </FormControl>
    );
};