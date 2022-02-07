import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';

export interface AutoInstallUpdatesFieldProps {
    helpText?: string;
}

export const AutoInstallUpdatesField = ({ helpText }: AutoInstallUpdatesFieldProps): JSX.Element => {
    const autoInstall: boolean = (useAppSelector(state => state.config.auto_install_updates) ?? false);

    return (
        <FormControl>
            <Checkbox id='auto_install_updates' isChecked={autoInstall} onChange={onCheckboxToggle}>Auto Install / Apply Updates</Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        When enabled, BlueBubbles will auto-install the latest available version when an update is detected
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};

