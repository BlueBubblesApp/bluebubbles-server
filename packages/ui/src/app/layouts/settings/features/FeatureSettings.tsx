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
import { AutoStartField } from '../../../components/fields/AutoStartField';
import { AutoCaffeinateField } from '../../../components/fields/AutoCaffeinateField';
import { DockBadgeField } from '../../../components/fields/DockBadgeField';
import { HideDockIconField } from '../../../components/fields/HideDockIconField';
import { StartViaTerminalField } from '../../../components/fields/StartViaTerminalField';
import { FacetimeDetectionField } from '../../../components/fields/FacetimeDetectionField';
import { StartMinimizedField } from '../../../components/fields/StartMinimizedField';


export const FeatureSettings = (): JSX.Element => {
    return (
        <section>
            <Stack direction='column' p={5}>
                <Text fontSize='2xl'>Features</Text>
                <Divider orientation='horizontal' />
                <Spacer />
                <FacetimeDetectionField />
                <Spacer />
                <AutoCaffeinateField />
                <Spacer />
                <AutoStartField />
                <Spacer />
                <StartMinimizedField />
                <Spacer />
                <DockBadgeField />
                <Spacer />
                <HideDockIconField />
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
                            <StartViaTerminalField />
                        </AccordionPanel>
                    </AccordionItem>
                </Accordion>
            </Stack>
        </section>
    );
};