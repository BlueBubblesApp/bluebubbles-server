import React from 'react';
import { Box, Text, Divider } from '@chakra-ui/react';
import { ConnectionSettings } from './connection/ConnectionSettings';
import { FeatureSettings } from './features/FeatureSettings';
import { UpdateSettings } from './update/UpdateSettings';
import { ResetSettings } from './reset/ResetSettings';
import { PermissionRequirements } from '../../components/PermissionRequirements';


export const SettingsLayout = (): JSX.Element => {
    return (
        <section>
            <Box p={3} borderRadius={10}>  
                <ConnectionSettings />
                <FeatureSettings />
                <UpdateSettings />
                <ResetSettings />

                <Text fontSize='2xl'>Permission Status</Text>
                <Divider orientation='horizontal' my={3}/>
                <PermissionRequirements />
            </Box>
        </section>
    );
};