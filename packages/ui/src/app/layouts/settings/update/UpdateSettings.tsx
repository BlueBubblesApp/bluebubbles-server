import React from 'react';
import {
    Divider,
    Stack,
    Text,
    Spacer
} from '@chakra-ui/react';
import { CheckForUpdatesField } from '../../../components/fields/CheckForUpdatesField';
import { AutoInstallUpdatesField } from '../../../components/fields/AutoInstallUpdatesField';


export const UpdateSettings = (): JSX.Element => {
    return (
        <section>
            <Stack direction='column' p={5}>
                <Text fontSize='2xl'>Update Settings</Text>
                <Divider orientation='horizontal' />
                <Spacer />
                <CheckForUpdatesField />
                <Spacer />
                <AutoInstallUpdatesField />
            </Stack>
        </section>
    );
};