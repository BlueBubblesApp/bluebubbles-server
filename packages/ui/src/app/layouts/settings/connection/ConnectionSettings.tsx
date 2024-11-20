import React from 'react';
import {
    Divider,
    Stack,
    Text,
    Spacer,
    Flex,
    Accordion,
    AccordionItem,
    AccordionButton,
    AccordionPanel,
    AccordionIcon,
    Box,
    Popover,
    PopoverCloseButton,
    PopoverContent,
    PopoverHeader,
    PopoverBody,
    PopoverArrow,
    PopoverTrigger,
} from '@chakra-ui/react';
import {  AiOutlineInfoCircle } from 'react-icons/ai';
import { useAppSelector } from '../../../hooks';
import { NgrokAuthTokenField } from '../../../components/fields/NgrokAuthTokenField';
import { ProxySetupField } from '../../../components/fields/ProxySetupField';
import { ServerPasswordField } from '../../../components/fields/ServerPasswordField';
import { LocalPortField } from '../../../components/fields/LocalPortField';
import { UseHttpsField } from '../../../components/fields/UseHttpsField';
import { ZrokTokenField } from 'app/components/fields/ZrokTokenField';
import { ZrokReserveTunnelField } from 'app/components/fields/ZrokReserveTunnelField';
import { ZrokReservedNameField } from 'app/components/fields/ZrokReservedNameField';
import { NgrokSubdomainField } from 'app/components/fields/NgrokSubdomainField';
import { ZrokDisableField } from 'app/components/fields/ZrokDisableField';
// import { EncryptCommunicationsField } from '../../../components/fields/EncryptCommunicationsField';


export const ConnectionSettings = (): JSX.Element => {
    const proxyService: string = (useAppSelector(state => state.config.proxy_service) ?? '').toLowerCase().replace(' ', '-');
    const zrokReserved: boolean = (useAppSelector(state => state.config.zrok_reserve_tunnel) ?? false);

    return (
        <Stack direction='column' p={5}>
            <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                <Text fontSize='2xl'>Connection Settings</Text>
                <Popover trigger='hover'>
                    <PopoverTrigger>
                        <Box ml={2} _hover={{ color: 'brand.primary', cursor: 'pointer' }}>
                            <AiOutlineInfoCircle />
                        </Box>
                    </PopoverTrigger>
                    <PopoverContent>
                        <PopoverArrow />
                        <PopoverCloseButton />
                        <PopoverHeader>Information</PopoverHeader>
                        <PopoverBody>
                            <Text>
                                These settings will determine how your clients will connect to the server
                            </Text>
                        </PopoverBody>
                    </PopoverContent>
                </Popover>
            </Flex>
            <Divider orientation='horizontal' />
            <Spacer />
            <ProxySetupField />
            {(proxyService === 'ngrok') ? (
                <>
                    <Spacer />
                    <NgrokAuthTokenField />
                    <Spacer />
                    <NgrokSubdomainField />
                </>
            ) : null}
            
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
                    <ZrokDisableField />
                </>
            ) : null}

            
            <Spacer />
            <Divider orientation='horizontal' />
            <ServerPasswordField />
            <LocalPortField />

            <Spacer />
            {(['dynamic-dns', 'lan-url'].includes(proxyService)) ? (
                <Accordion allowMultiple>
                    <AccordionItem>
                        <AccordionButton>
                            <Box flex='1' textAlign='left' width="15em">
                                Advanced Connection Settings
                            </Box>
                            <AccordionIcon />
                        </AccordionButton>
                        <AccordionPanel pb={4}>
                            {/* <EncryptCommunicationsField />
                            <Box m={15} /> */}
                            <UseHttpsField />
                        </AccordionPanel>
                    </AccordionItem>
                </Accordion>
            ) : null}
        </Stack>
    );
};