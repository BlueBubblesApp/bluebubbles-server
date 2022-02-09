import React, { useRef } from 'react';
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


export interface ProxyServiceFieldProps {
    helpText?: string;
    showAddress?: boolean;
}

export const ProxyServiceField = ({ helpText, showAddress = true }: ProxyServiceFieldProps): JSX.Element => {
    const dispatch = useAppDispatch();
    const dnsRef = useRef(null);
    const proxyService: string = (useAppSelector(state => state.config.proxy_service) ?? '').toLowerCase().replace(' ', '-');
    const address: string = useAppSelector(state => state.config.server_address) ?? '';
    const port: number = useAppSelector(state => state.config.socket_port) ?? 1234;
    const [dnsModalOpen, setDnsModalOpen] = useBoolean();
    return (
        <FormControl>
            <FormLabel htmlFor='proxy_service'>Proxy Service</FormLabel>
            <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                <Select
                    id='proxy_service'
                    placeholder='Select Proxy Service'
                    maxWidth="15em"
                    mr={3}
                    value={proxyService}
                    onChange={(e) => {
                        if (!e.target.value || e.target.value.length === 0) return;
                        onSelectChange(e);
                        if (e.target.value === 'dynamic-dns') {
                            setDnsModalOpen.on();
                        }
                    }}
                >
                    <option value='ngrok'>Ngrok</option>
                    <option value='cloudflare'>Cloudflare</option>
                    <option value='dynamic-dns'>Dynamic DNS</option>
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
        </FormControl>
    );
};