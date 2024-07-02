import React from 'react';
import {
    Divider,
    Stack,
    Text,
    Spacer,
    Accordion,
    AccordionItem,
    AccordionButton,
    AccordionPanel,
    AccordionIcon,
    Box
} from '@chakra-ui/react';
import { AutoStartMethodField } from '../../../components/fields/AutoStartMethodField';
import { AutoCaffeinateField } from '../../../components/fields/AutoCaffeinateField';
import { DockBadgeField } from '../../../components/fields/DockBadgeField';
import { HideDockIconField } from '../../../components/fields/HideDockIconField';
import { StartViaTerminalField } from '../../../components/fields/StartViaTerminalField';
import { StartMinimizedField } from '../../../components/fields/StartMinimizedField';
import { StartDelayField } from 'app/components/fields/StartDelayField';
import { LandingPageField } from 'app/components/fields/LandingPageField';
import { OpenFindMyOnStartupField } from 'app/components/fields/OpenFindMyOnStartupField';
import { AutoLockMacField } from 'app/components/fields/AutoLockMacField';


export const FeatureSettings = (): JSX.Element => {
    return (
        <section>
            <Stack direction='column' p={5}>
                <Text fontSize='2xl'>Features</Text>
                <Divider orientation='horizontal' />
                <Spacer />
                <OpenFindMyOnStartupField />
                <Spacer />
                <AutoCaffeinateField />
                <Spacer />
                <AutoStartMethodField />
                <Spacer />
                <StartMinimizedField />
                <Spacer />
                <AutoLockMacField />
                <Spacer />
                <DockBadgeField />
                <Spacer />
                <HideDockIconField />
                <Spacer />
                <StartDelayField />
                <Spacer />
                <Accordion allowMultiple>
                    <AccordionItem>
                        <AccordionButton>
                            <Box flex='1' textAlign='left' width="15em">
                                Advanced Feature Settings
                            </Box>
                            <AccordionIcon />
                        </AccordionButton>
                        <AccordionPanel pb={4}>
                            <Stack direction='column'>
                                <StartViaTerminalField />
                                <Spacer />
                                <LandingPageField />
                            </Stack>
                        </AccordionPanel>
                    </AccordionItem>
                </Accordion>
            </Stack>
        </section>
    );
};