import React from 'react';
import {
    Box,
    Text,
    SlideFade,
    Image
} from '@chakra-ui/react';
import { PermissionRequirements } from '../../../components/PermissionRequirements';
import FullDiskImage from '../../../../images/walkthrough/full-disk-access.png';
import SystemPreferencesImage from '../../../../images/walkthrough/system-preferences.png';

export const PermissionsWalkthrough = (): JSX.Element => {
    return (
        <SlideFade in={true} offsetY='150px'>
            <Box px={5}>
                <Text fontSize='4xl'>Permissions</Text>
                <Text fontSize='md' mt={5}>
                    Before setting up BlueBubbles, we need to make sure that the app is given the correct permissions
                    so that it can operate. The main permission that is required is the <strong>Full Disk Access</strong>&nbsp;
                    permission. This will allow BlueBubbles to read the iMessage database and provide notifications for
                    new messages. Accessibility permissions are optional and are not required for the base BlueBubbles functionality.
                </Text>
                <Text fontSize='md' mt={5}>
                    Here is an evaluation of your current permissions. If Full Disk Access is not enabled, you will not be
                    able to use BlueBubbles
                </Text>
                <Box my={3} />
                <PermissionRequirements />
                <Text fontSize='lg' my={5}><b>Quick Guide</b></Text>
                <Text fontSize='md' mt={5}>
                    Use the gear icon next to a permission failure above to open System Preferences,
                    then add/enable BlueBubbles:
                </Text>
                <Image src={SystemPreferencesImage} borderRadius='lg' my={2} />
                <Image src={FullDiskImage} borderRadius='lg' my={2} />
                
            </Box>
        </SlideFade>
    );
};