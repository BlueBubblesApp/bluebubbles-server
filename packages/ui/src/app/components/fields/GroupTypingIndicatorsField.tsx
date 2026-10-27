import React from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';

export interface GroupTypingIndicatorsFieldProps {
    helpText?: string;
}

export const GroupTypingIndicatorsField = ({ helpText }: GroupTypingIndicatorsFieldProps): JSX.Element => {
    const enabled: boolean = (useAppSelector(state => state.config.group_typing_indicators) ?? false);

    return (
        <FormControl>
            <Checkbox id='group_typing_indicators' isChecked={enabled} onChange={onCheckboxToggle}>Group Typing Indicators</Checkbox>
            <FormHelperText>
                {helpText ?? (
                    <Text>
                        When enabled, typing indicators from group chats will be forwarded to connected clients,
                        instead of being dropped. On iPhone, typing indicators also appear in group chats.
                        Note: macOS may not report who is typing in group chats, so clients may only be able
                        to show a generic indicator. Requires the Private API to be enabled.
                    </Text>
                )}
            </FormHelperText>
        </FormControl>
    );
};
