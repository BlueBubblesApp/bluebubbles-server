import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';

export interface ZrokReserveTunnelFieldProps {
    helpText?: string;
}

export const ZrokReserveTunnelField = ({ helpText }: ZrokReserveTunnelFieldProps): JSX.Element => {
    const reserveTunnel: boolean = (useAppSelector(state => state.config.zrok_reserve_tunnel) ?? false);

    return (
        <FormControl>
            <Checkbox id='zrok_reserve_tunnel' isChecked={reserveTunnel} onChange={onCheckboxToggle}>Reserve a Static Subdomain</Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        Enabling this will create a reserved tunnel with Zrok.
                        This means your Zrok URL will be static and never change.
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};

