import React from 'react';
import { Box, Text, Divider } from '@chakra-ui/react';
import { ConnectionSettings } from './connection/ConnectionSettings';
import { FeatureSettings } from './features/FeatureSettings';
import { UpdateSettings } from './update/UpdateSettings';
import { ResetSettings } from './reset/ResetSettings';
import { ThemeSettings } from './theme/ThemeSettings';
import { DatabaseSettings } from './database/DatabaseSettings';
import { PermissionRequirements } from '../../components/PermissionRequirements';


export const SettingsLayout = (): JSX.Element => {
    return (
        <section>
            <Box p={3} borderRadius={10}>  
                <ConnectionSettings />
                <FeatureSettings />
                <DatabaseSettings />
                <UpdateSettings />
                <ThemeSettings />
                <Box p={5}>
                    <Text fontSize='2xl'>Permission Status</Text>
                    <Divider orientation='horizontal' my={3}/>
                    <PermissionRequirements />
                </Box>
                <ResetSettings />
            </Box>
        </section>
    );
};