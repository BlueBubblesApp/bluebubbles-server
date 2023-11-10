import React from 'react';
import {
    Box,
    Text,
    Heading,
    LinkBox,
    LinkOverlay,
    SlideFade,
    Alert,
    AlertIcon
} from '@chakra-ui/react';
import { PrivateApiField } from '../../../components/fields/PrivateApiField';


export const PrivateApiWalkthrough = (): JSX.Element => {
    return (
        <SlideFade in={true} offsetY='150px'>
            <Box px={5}>
                <Text fontSize='4xl'>Private API Setup (Advanced | Optional)</Text>
                <Text fontSize='md' mt={5}>
                    You may already know this, but BlueBubbles is one of the only cross-platform iMessage solution that
                    supports sending reactions, replies, subjects, and effects. This is because we developed an Objective-C
                    library that allows us to interface with Apple's "Private APIs". Normally, this is not possible, however,
                    after disabling your macOS device's SIP controls, these private APIs are made accessible.
                </Text>
                <Text fontSize='md' mt={5}>
                    If you would like to find out more information, please go to the link below:
                </Text>
                <LinkBox as='article' maxW='sm' px='5' pb={5} pt={2} mt={5} borderWidth='1px' rounded='xl'>
                    <Text color='gray'>
                        https://docs.bluebubbles.app/private-api/
                    </Text>
                    <Heading size='md' my={2}>
                        <LinkOverlay href='https://bluebubbles.app/donate' target='_blank'>
                            Private API Documentation
                        </LinkOverlay>
                    </Heading>
                    <Text>
                        This documentation will go over the pros and cons to setting up the Private API. It will speak to
                        the risks of disabling SIP controls, as well as the full feature set that uses the Private API
                    </Text>
                </LinkBox>
                <Text fontSize='3xl' mt={5}>Configurations</Text>
                <Alert status='info' mt={2}>
                    <AlertIcon />
                    Unless you know what you're doing, please make sure the following Private API Requirements all pass
                    before enabling the setting.
                </Alert>
                <Box mt={4} />
                <PrivateApiField />
            </Box>
        </SlideFade>
    );
};