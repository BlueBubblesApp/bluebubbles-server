import React from 'react';
import {
    Divider,
    Stack,
    Text,
    Spacer
} from '@chakra-ui/react';
import { PollIntervalField } from '../../../components/fields/PollIntervalField';


export const DatabaseSettings = (): JSX.Element => {
    return (
        <section>
            <Stack direction='column' p={5}>
                <Text fontSize='2xl'>Database Settings</Text>
                <Divider orientation='horizontal' />
                <Spacer />
                <PollIntervalField />
            </Stack>
        </section>
    );
};