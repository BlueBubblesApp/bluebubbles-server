import React from 'react';
import {
    Box,
    Text,
    SlideFade,
    Stack,
    Alert,
    AlertIcon,
    Spacer
} from '@chakra-ui/react';
import { ProxySetupField } from '../../../components/fields/ProxySetupField';
import { useAppSelector } from '../../../hooks';
import { NgrokAuthTokenField } from '../../../components/fields/NgrokAuthTokenField';
import { ServerPasswordField } from '../../../components/fields/ServerPasswordField';
import { ZrokTokenField } from 'app/components/fields/ZrokTokenField';
import { ZrokReservedNameField } from 'app/components/fields/ZrokReservedNameField';
import { ZrokReserveTunnelField } from 'app/components/fields/ZrokReserveTunnelField';
import { NgrokSubdomainField } from 'app/components/fields/NgrokSubdomainField';

export const ConnectionWalkthrough = (): JSX.Element => {
    const proxyService: string = (useAppSelector(state => state.config.proxy_service) ?? '').toLowerCase().replace(' ', '-');
    const zrokReserved: boolean = (useAppSelector(state => state.config.zrok_reserve_tunnel) ?? false);

    return (
        <SlideFade in={true} offsetY='150px'>
            <Box px={5}>
                <Text fontSize='4xl'>Connection Setup</Text>
                <Text fontSize='md' mt={5}>
                    In order for you to be able to connect to this BlueBubbles server from the internet, you'll need
                    to either setup a Dynamic DNS or use one of the integrated proxy services. Proxy services create
                    a tunnel from your macOS device to your BlueBubbles clients. It does this by routing all communications
                    from your BlueBubbles server, through the proxy service's servers, and to your BlueBubbles client. Without
                    this, your BlueBubbles server will only be accessible on your local network.
                </Text>
                <Text fontSize='md' mt={5}>
                    Now, we also do not want anyone else to be able to access your BlueBubbles server except you, so we have
                    setup password-based authentication. All clients will be required to provide the password in order to
                    interact with the BlueBubbles Server's API.
                </Text>
                <Text fontSize='md' mt={5}>
                    Below, you'll be asked to set a password, as well as select the proxy service that you would like to use.
                    Just note, by 
                </Text>

                <Text fontSize='3xl' mt={5}>Configurations</Text>
                <Alert status='info' mt={2}>
                    <AlertIcon />
                    You must&nbsp;<i>at minimum</i>&nbsp;set a password and a proxy service
                </Alert>

                <Stack direction='column' p={5}>
                    <ServerPasswordField errorOnEmpty={true} />
                    <ProxySetupField />
                    {(proxyService === 'ngrok') ? (
                        <>
                            <NgrokAuthTokenField />
                            <Spacer />
                            <NgrokSubdomainField />
                        </>
                    ): null}
                    {(proxyService === 'zrok') ? (
                        <>
                            <Spacer />
                            <ZrokTokenField />
                            <Spacer />
                            <ZrokReserveTunnelField />
                            {zrokReserved ? (
                                <>
                                    <Spacer />
                                    <ZrokReservedNameField />
                                </>
                            ) : null}
                        </>
                    ) : null}
                </Stack>
            </Box>
        </SlideFade>
    );
};