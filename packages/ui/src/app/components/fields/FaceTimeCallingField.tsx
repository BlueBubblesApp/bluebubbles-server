import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';

export interface ExperimentalFaceTimeFeaturesFieldProps {
    helpText?: string;
}

export const FaceTimeCallingField = ({ helpText }: ExperimentalFaceTimeFeaturesFieldProps): JSX.Element => {
    const experimentalFeatures: boolean = (useAppSelector(state => state.config.facetime_calling) ?? false);

    return (
        <FormControl>
            <Checkbox id='facetime_calling' isChecked={experimentalFeatures}  onChange={onCheckboxToggle}>FaceTime Calling (Experimental)</Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        When enabled, the server will detect incoming FaceTime calls and attempt
                        to generate a link for it. It'll then send a notification to connected
                        devices, allowing you to join remotely.
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};

