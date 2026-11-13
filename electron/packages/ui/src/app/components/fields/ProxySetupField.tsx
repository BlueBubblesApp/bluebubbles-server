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
import { saveLanUrl } from 'app/utils/IpcUtils';
import { NgrokSetupDialog } from '../modals/NgrokSetupDialog';
import { ZrokSetupDialog } from '../modals/ZrokSetupDialog';


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
    const ngrokRef = useRef(null);
    const zrokRef = useRef(null);
    const alertRef = useRef(null);
    const proxyService: string = (useAppSelector(state => state.config.proxy_service) ?? '').toLowerCase().replace(' ', '-');
    const address: string = useAppSelector(state => state.config.server_address) ?? '';
    const port: number = useAppSelector(state => state.config.socket_port) ?? 1234;
    const [dnsModalOpen, setDnsModalOpen] = useBoolean();
    const [ngrokModalOpen, setNgrokModalOpen] = useBoolean();
    const [zrokModalOpen, setZrokModalOpen] = useBoolean();
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

                        let shouldSave = true;
                        if (e.target.value === 'dynamic-dns') {
                            shouldSave = false;
                            setDnsModalOpen.on();
                        } else if (e.target.value === 'ngrok') {
                            shouldSave = false;
                            setNgrokModalOpen.on();
                        } else if (e.target.value === 'zrok') {
                            shouldSave = false;
                            setZrokModalOpen.on();
                        } else if (e.target.value === 'cloudflare') {
                            confirm('confirmation');
                        } else if (e.target.value === 'lan-url') {
                            saveLanUrl();
                        }

                        if (shouldSave) {
                            onSelectChange(e);
                        }
                    }}
                >
                    <option value='cloudflare'>Cloudflare (Recommended)</option>
                    <option value='zrok'>Zrok</option>
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
                onConfirm={(address) => {
                    dispatch(setConfig({ name: 'proxy_service', value: 'Dynamic DNS' }));
                    dispatch(setConfig({ name: 'server_address', value: address }));
                }}
                isOpen={dnsModalOpen}
                port={port as number}
                onClose={() => setDnsModalOpen.off()}
            />

            <NgrokSetupDialog
                modalRef={ngrokRef}
                onConfirm={(token: string) => {
                    dispatch(setConfig({ name: 'proxy_service', value: 'Ngrok' }));
                    dispatch(setConfig({ name: 'ngrok_key', value: token }));
                }}
                isOpen={ngrokModalOpen}
                onClose={() => setNgrokModalOpen.off()}
            />

            <ZrokSetupDialog
                modalRef={zrokRef}
                onConfirm={(token: string) => {
                    dispatch(setConfig({ name: 'proxy_service', value: 'Zrok' }));
                    dispatch(setConfig({ name: 'zrok_token', value: token }));
                }}
                isOpen={zrokModalOpen}
                onClose={() => setZrokModalOpen.off()}
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