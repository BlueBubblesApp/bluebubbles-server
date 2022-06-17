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
import { NgrokRegionField } from '../../../components/fields/NgrokRegionField';
import { NgrokAuthTokenField } from '../../../components/fields/NgrokAuthTokenField';
import { NgrokAuthCredentialsFields } from '../../../components/fields/NgrokAuthCredentialsFields';
import { ProxyServiceField } from '../../../components/fields/ProxyServiceField';
import { ServerPasswordField } from '../../../components/fields/ServerPasswordField';
import { LocalPortField } from '../../../components/fields/LocalPortField';
import { UseHttpsField } from '../../../components/fields/UseHttpsField';
import { EncryptCommunicationsField } from '../../../components/fields/EncryptCommunicationsField';


export const ConnectionSettings = (): JSX.Element => {
    const proxyService: string = (useAppSelector(state => state.config.proxy_service) ?? '').toLowerCase().replace(' ', '-');
    const ngrokToken: string = (useAppSelector(state => state.config.ngrok_key) ?? '').toLowerCase();

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
            <ProxyServiceField />
            <Spacer />
            {(proxyService === 'ngrok') ? (<NgrokRegionField />) : null}
            <Spacer />
            {(proxyService === 'ngrok') ? (<NgrokAuthTokenField />) : null}
            <Spacer />
            {(proxyService === 'ngrok' && ngrokToken != '') ? (<NgrokAuthCredentialsFields />) : null}
            <Spacer />
            <Divider orientation='horizontal' />
            <ServerPasswordField />
            <LocalPortField />

            <Spacer />
            <Accordion allowMultiple>
                <AccordionItem>
                    <AccordionButton>
                        <Box flex='1' textAlign='left' width="15em">
                            Advanced Connection Settings
                        </Box>
                        <AccordionIcon />
                    </AccordionButton>
                    <AccordionPanel pb={4}>
                        <EncryptCommunicationsField />
                        <Box m={15} />
                        {(proxyService === 'dynamic-dns') ? (<UseHttpsField />) : null}
                    </AccordionPanel>
                </AccordionItem>
            </Accordion>
        </Stack>
    );
};