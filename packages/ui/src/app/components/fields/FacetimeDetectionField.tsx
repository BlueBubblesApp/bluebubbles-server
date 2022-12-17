import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';


export interface FacetimeDetectionFieldProps {
    helpText?: string;
}

export const FacetimeDetectionField = ({ helpText }: FacetimeDetectionFieldProps): JSX.Element => {
    const facetimeDetection: boolean = (useAppSelector(state => state.config.facetime_detection) ?? false);

    return (
        <FormControl>
            <Checkbox id='facetime_detection' isChecked={facetimeDetection} onChange={onCheckboxToggle}>Incoming Facetime Detection</Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <>
                        <Text>
                            Enabling this will allow BlueBubbles to detect incoming Facetime calls and notify clients.
                        </Text>
                        <Text>
                            <b>This requires the <i>Accessibility Permission</i>.</b>
                        </Text>
                    </>
                )}
            </FormHelperText>
        </FormControl>
    );
};