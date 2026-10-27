import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';

export interface WebhookApiPrivateAddressesFieldProps {
    helpText?: string;
}

export const WebhookApiPrivateAddressesField = ({ helpText }: WebhookApiPrivateAddressesFieldProps): JSX.Element => {
    const allowPrivate: boolean = (useAppSelector(state => state.config.webhook_api_allow_private_addresses) ?? false);

    return (
        <FormControl>
            <Checkbox
                id='webhook_api_allow_private_addresses'
                isChecked={allowPrivate}
                onChange={onCheckboxToggle}
            >
                Allow API webhooks to reach local network addresses
            </Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        Webhooks registered through the REST API are blocked from targeting localhost, your LAN, and
                        other non-public addresses unless this is enabled. Only enable it if an integration registers
                        a webhook pointing at your own network. Webhooks added here can be configured individually.
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};
