import React from 'react';
import { Box, Text, Divider, Stack } from '@chakra-ui/react';
import { ConnectionSettings } from './connection/ConnectionSettings';
import { FeatureSettings } from './features/FeatureSettings';
import { PrivateApiSettings } from './privateApi/PrivateApiSettings';
import { UpdateSettings } from './update/UpdateSettings';
import { ResetSettings } from './reset/ResetSettings';
import { ThemeSettings } from './theme/ThemeSettings';
import { PermissionRequirements } from '../../components/PermissionRequirements';
import { AttachmentCacheBox } from 'app/components/AttachmentCacheBox';


export const SettingsLayout = (): JSX.Element => {
    return (
        <section>
            <Box p={3} borderRadius={10}>  
                <ConnectionSettings />
                <PrivateApiSettings />
                <FeatureSettings />
                <UpdateSettings />
                <ThemeSettings />
                <Stack direction='row' align='flex-start' flexWrap='wrap' p={5}>
                    <Box>
                        <Text fontSize='2xl'>Permission Status</Text>
                        <Divider orientation='horizontal' my={3}/>
                        <PermissionRequirements />
                    </Box>
                    <Box pl={5}>
                        <Text fontSize='2xl'>Attachment Management</Text>
                        <Divider orientation='horizontal' my={3}/>
                        <AttachmentCacheBox />
                    </Box>
                </Stack>
                
                <ResetSettings />
            </Box>
        </section>
    );
};