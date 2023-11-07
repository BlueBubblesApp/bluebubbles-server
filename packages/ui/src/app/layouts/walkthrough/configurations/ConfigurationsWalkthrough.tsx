import React from 'react';
import {
    Box,
    Text,
    SlideFade,
} from '@chakra-ui/react';
import { AutoStartField } from '../../../components/fields/AutoStartField';
import { AutoCaffeinateField } from '../../../components/fields/AutoCaffeinateField';
import { CheckForUpdatesField } from '../../../components/fields/CheckForUpdatesField';
import { AutoInstallUpdatesField } from '../../../components/fields/AutoInstallUpdatesField';
import { UseOledDarkModeField } from '../../../components/fields/OledDarkThemeField';


export const ConfigurationsWalkthrough = (): JSX.Element => {
    return (
        <SlideFade in={true} offsetY='150px'>
            <Box px={5}>
                <Text fontSize='4xl'>Setup Complete!</Text>
                <Text fontSize='md' mt={5}>
                    Congratulations, you have completed the BlueBubbles Server setup! Here are some useful features that
                    you may want to checkout to customize your BlueBubbles experience!
                </Text>
                <Text fontSize='3xl' mt={5}>Features</Text>
                <Box my={3} />
                <AutoStartField />
                <Box my={3} />
                <AutoCaffeinateField />
                <Text fontSize='3xl' mt={5}>Update Settings</Text>
                <Box my={3} />
                <CheckForUpdatesField />
                <Box my={3} />
                <AutoInstallUpdatesField />
                <Text fontSize='3xl' mt={5}>Theme Settings</Text>
                <Box my={3} />
                <UseOledDarkModeField />
            </Box>
        </SlideFade>
    );
};