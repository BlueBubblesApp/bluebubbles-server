import React from 'react';
import {
    Divider,
    Stack,
    Text,
    Spacer
} from '@chakra-ui/react';
import { PrivateApiField } from '../../../components/fields/PrivateApiField';
import { PrivateApiModeField } from 'app/components/fields/PrivateApiModeField';


export const PrivateApiSettings = (): JSX.Element => {
    return (
        <section>
            <Stack direction='column' p={5}>
                <Text fontSize='2xl'>Private API</Text>
                <Divider orientation='horizontal' />
                <Spacer />
                <PrivateApiField />
                <PrivateApiModeField />
            </Stack>
        </section>
    );
};