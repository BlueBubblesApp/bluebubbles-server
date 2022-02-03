import React from 'react';
import {
    Divider,
    Stack,
    Text,
    FormControl,
    FormHelperText,
    Checkbox,
    Spacer,
    Accordion,
    AccordionItem,
    AccordionButton,
    AccordionPanel,
    AccordionIcon,
    Box
} from '@chakra-ui/react';
import { useAppSelector } from '../../../hooks';
import { onCheckboxToggle } from '../../../actions/ConfigActions';
import { AutoStartField } from '../../../components/fields/AutoStartField';
import { AutoCaffeinateField } from '../../../components/fields/AutoCaffeinateField';
import { PrivateApiField } from '../../../components/fields/PrivateApiField';


export const FeatureSettings = (): JSX.Element => {
    const hideDockIcon = (useAppSelector(state => state.config.hide_dock_icon) ?? false);
    const useTerminal = (useAppSelector(state => state.config.start_via_terminal) ?? false);
    return (
        <section>
            <Stack direction='column' p={5}>
                <Text fontSize='2xl'>Features</Text>
                <Divider orientation='horizontal' />
                <Spacer />
                <PrivateApiField />
                <Spacer />
                <AutoCaffeinateField />
                <Spacer />
                <AutoStartField />
                <Spacer />

                <FormControl>
                    <Checkbox id='hide_dock_icon' isChecked={hideDockIcon} onChange={onCheckboxToggle}>Hide Dock Icon</Checkbox>
                    <FormHelperText>
                        Hiding the dock icon will not close the app. You can open the app again via the status bar icon.
                    </FormHelperText>
                </FormControl>

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
                            <FormControl>
                                <Checkbox id='start_via_terminal' isChecked={useTerminal} onChange={onCheckboxToggle}>Always Start via Terminal</Checkbox>
                                <FormHelperText>
                                    When BlueBubbles starts up, it will auto-reload itself in terminal mode.
                                    When in terminal, type `help` for command information.
                                </FormHelperText>
                            </FormControl>
                        </AccordionPanel>
                    </AccordionItem>
                </Accordion>
            </Stack>
        </section>
    );
};