import React, { useRef, useState } from 'react';
import {
    Select,
    Flex,
    FormControl,
    FormLabel,
    FormHelperText,
    useBoolean,
    IconButton,
    Text,

} from '@chakra-ui/react';
import { useAppDispatch, useAppSelector } from '../../hooks';
import { onSelectChange } from '../../actions/ConfigActions';
import { DynamicDnsDialog } from '../modals/DynamicDnsDialog';
import { AiOutlineEdit } from 'react-icons/ai';
import { BiCopy } from 'react-icons/bi';
import { setConfig } from '../../slices/ConfigSlice';
import { copyToClipboard } from '../../utils/GenericUtils';
import { ConfirmationItems } from '../../utils/ToastUtils';
import { ConfirmationDialog } from '../modals/ConfirmationDialog';


export interface ProxySetupFieldProps {
    helpText?: string;
    showAddress?: boolean;
}

const confirmationActions: ConfirmationItems = {
    confirmation: {
        message: (
            'Cloudflare registers brand new domains on the fly to assign to your server. After ' +
            'switching your proxy service to Cloudflare, it is highly recommended that you toggle your ' + 
            'client device\'s WiFi/Network off and then back on.<br /><br />Note: This is to ensure that new ' +
            'domains can be found by your device\'s DNS service.'
        ),
        func: () => {
            // Do nothing
        }
    }
};

export const ProxySetupField = ({ helpText, showAddress = true }: ProxySetupFieldProps): JSX.Element => {
    const dispatch = useAppDispatch();
    const dnsRef = useRef(null);
    const alertRef = useRef(null);
    const proxyService: string = (useAppSelector(state => state.config.proxy_service) ?? '').toLowerCase().replace(' ', '-');
    const useCustomCertificate: boolean = useAppSelector(state => state.config.use_custom_certificate) ?? false;
    const address: string = useAppSelector(state => state.config.server_address) ?? '';
    const port: number = useAppSelector(state => state.config.socket_port) ?? 1234;
    const [dnsModalOpen, setDnsModalOpen] = useBoolean();
    const [requiresConfirmation, confirm] = useState((): string | null => {
        return null;
    });

    return (
        <FormControl>
            <FormLabel htmlFor='proxy_service'>Proxy Setup</FormLabel>
            <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                <Select
                    id='proxy_service'
                    maxWidth="16em"
                    mr={3}
                    value={proxyService}
                    onChange={(e) => {
                        if (!e.target.value || e.target.value.length === 0) return;
                        onSelectChange(e);
                        if (e.target.value === 'dynamic-dns') {
                            setDnsModalOpen.on();
                        } else if (e.target.value === 'cloudflare') {
                            confirm('confirmation');
                        } else if (e.target.value === 'lan-url') {
                            const addr = `${(useCustomCertificate) ? 'https' : 'http'}://localhost:${port}`;
                            dispatch(setConfig({ name: 'server_address', value: addr }));
                        }
                    }}
                >
                    <option value='cloudflare'>Cloudflare (Recommended)</option>
                    <option value='ngrok'>Ngrok</option>
                    <option value='dynamic-dns'>Dynamic DNS / Custom URL</option>
                    <option value='lan-url'>LAN URL</option>
                </Select>
                {(proxyService === 'dynamic-dns')
                    ? (
                        <IconButton
                            mr={3}
                            aria-label='Set address'
                            icon={<AiOutlineEdit />}
                            onClick={() => setDnsModalOpen.on()}
                        />
                    ) : null}
                {(showAddress) ? (
                    <>
                        <Text fontSize="md" color="grey">Address: {address}</Text>
                        <IconButton
                            ml={3}
                            aria-label='Copy address'
                            icon={<BiCopy />}
                            onClick={() => copyToClipboard(address)}
                        />
                    </>
                ) : null}
            </Flex>
            <FormHelperText>
                {helpText ?? 'Select a proxy service to use to make your server internet-accessible. Without one selected, your server will only be accessible on your local network'}
            </FormHelperText>

            <DynamicDnsDialog
                modalRef={dnsRef}
                onConfirm={(address) => dispatch(setConfig({ name: 'server_address', value: address }))}
                isOpen={dnsModalOpen}
                port={port as number}
                onClose={() => setDnsModalOpen.off()}
            />

            <ConfirmationDialog
                title="Notice"
                modalRef={alertRef}
                onClose={() => confirm(null)}
                body={confirmationActions[requiresConfirmation as string]?.message}
                acceptText="OK"
                declineText={null}
                onAccept={() => {
                    confirmationActions[requiresConfirmation as string].func();
                }}
                isOpen={requiresConfirmation !== null}
            />
        </FormControl>
    );
};