import React from 'react';
import {
    Divider,
    Stack,
    Text,
    Spacer
} from '@chakra-ui/react';
import { UseOledDarkModeField } from '../../../components/fields/OledDarkThemeField';


export const ThemeSettings = (): JSX.Element => {
    return (
        <section>
            <Stack direction='column' p={5}>
                <Text fontSize='2xl'>Theme Settings</Text>
                <Divider orientation='horizontal' />
                <Spacer />
                <UseOledDarkModeField />
            </Stack>
        </section>
    );
};