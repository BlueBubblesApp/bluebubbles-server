import React, { useState } from 'react';
import {
    AlertDialog,
    AlertDialogOverlay,
    AlertDialogBody,
    AlertDialogContent,
    AlertDialogFooter,
    AlertDialogHeader,
    Button,
    Input,
    FormControl,
    FormErrorMessage,
    FormLabel,
    Text,
} from '@chakra-ui/react';
import { FocusableElement } from '@chakra-ui/utils';
import { ScheduledMessageItem } from '../tables/ScheduledMessagesTable';
import { GroupBase, Options, Select } from 'chakra-react-select';
import { scheduledMessageTypeOptions } from 'app/constants';


interface ScheduledMessageDialogProps {
    onCancel?: () => void;
    onCreate?: (message: ScheduledMessageItem) => void;
    onClose: () => void;
    isOpen: boolean;
    modalRef: React.RefObject<FocusableElement>;
}

export const ScheduledMessageDialog = ({
    onCancel,
    onCreate,
    onClose,
    isOpen,
    modalRef,
}: ScheduledMessageDialogProps): JSX.Element => {
    const [type, setType] = useState(scheduledMessageTypeOptions[0] as any | null);
    const [message, setMessage] = useState('');
    const [chatGuid, setChatGuid] = useState('');
    const [scheduledFor, setScheduledFor] = useState(null as Date | null);
    const [scheduleType, setScheduleType] = useState('once');
    const [intervalType, setIntervalType] = useState(null as string | null);
    const [interval, setIntervalValue] = useState(null as number | null);
    const [messageError, setMessageError] = useState('');
    const hasMessageError = (messageError ?? '').length > 0;
    const [guidError, setGuidError] = useState('');
    const hasGuidError = (guidError ?? '').length > 0;
    const [dateError, setDateError] = useState('');
    const hasDateError = (dateError ?? '').length > 0;


    const _onClose = () => {
        setType('send-message');
        setMessage('');
        setChatGuid('');
        setScheduledFor(null);
        setScheduleType('once');
        setIntervalType(null);
        setIntervalValue(null);
        setMessageError('');
        setGuidError('');

        if (onClose) onClose();
    };

    return (
        <AlertDialog
            isOpen={isOpen}
            leastDestructiveRef={modalRef}
            onClose={() => onClose()}
        >
            <AlertDialogOverlay>
                <AlertDialogContent>
                    <AlertDialogHeader fontSize='lg' fontWeight='bold'>
                        Schedule a Message
                    </AlertDialogHeader>

                    <AlertDialogBody>
                        <FormControl mt={5}>
                            <FormLabel>Type</FormLabel>
                            <Select
                                size='md'
                                options={scheduledMessageTypeOptions as unknown as Options<string>}
                                value={type}
                                onChange={setType}
                            />
                        </FormControl>
                        <FormControl isInvalid={hasGuidError} mt={5}>
                            <FormLabel htmlFor='message'>Phone Number / Chat GUID</FormLabel>
                            <Input
                                id='chatGuid'
                                type='text'
                                value={chatGuid ?? ''}
                                placeholder=''
                                onChange={(e) => {
                                    setGuidError('');
                                    setChatGuid(e.target.value);
                                }}
                            />
                            {hasGuidError ? (
                                <FormErrorMessage>{guidError}</FormErrorMessage>
                            ) : null}
                        </FormControl>
                        <FormControl isInvalid={hasMessageError} mt={5}>
                            <FormLabel htmlFor='message'>Message</FormLabel>
                            <Input
                                id='message'
                                type='text'
                                value={message}
                                placeholder='Good morning :)'
                                onChange={(e) => {
                                    setMessageError('');
                                    setMessage(e.target.value);
                                }}
                            />
                            {hasMessageError ? (
                                <FormErrorMessage>{messageError}</FormErrorMessage>
                            ) : null}
                        </FormControl>
                        {/* <FormControl mt={5}>
                            <FormLabel>Schedule Type</FormLabel>
                            <Select
                                size='md'
                                options={scheduledMessageTypeOptions as unknown as Options<string>}
                                value={type}
                                onChange={setType}
                            />
                        </FormControl> */}
                        <FormControl isInvalid={hasDateError} mt={5}>
                            <FormLabel htmlFor='scheduledFor'>Scheduled For</FormLabel>
                            <Input
                                id='scheduledFor'
                                type='datetime-local'
                                value={scheduledFor?.toISOString().split('.')[0] ?? ''}
                                onChange={(e) => {
                                    setDateError('');
                                    setScheduledFor(new Date(e.target.value));
                                }}
                            />
                            {hasDateError ? (
                                <FormErrorMessage>{dateError}</FormErrorMessage>
                            ) : null}
                        </FormControl>
                    </AlertDialogBody>

                    <AlertDialogFooter>
                        <Button
                            ref={modalRef as React.LegacyRef<HTMLButtonElement> | undefined}
                            onClick={() => {
                                if (onCancel) onCancel();
                                _onClose();
                            }}
                        >
                            Cancel
                        </Button>
                        <Button
                            ml={3}
                            bg='brand.primary'
                            ref={modalRef as React.LegacyRef<HTMLButtonElement> | undefined}
                            onClick={() => {
                                if (message.length === 0) {
                                    setMessageError('Please enter a message to send!');
                                    return;
                                }

                                if (chatGuid.length === 0) {
                                    setGuidError('Please enter a phone number or chat GUID!');
                                    return;
                                }

                                let guid = chatGuid;
                                if (!guid.startsWith('iMessage;-;')) {
                                    guid = `iMessage;-;${guid}`;
                                }

                                const now = new Date();
                                if (!scheduledFor || scheduledFor < now) {
                                    setDateError('Please enter a date in the future!');
                                    return;
                                }

                                if (onCreate) {
                                    onCreate({
                                        id: null,
                                        type: type?.value ?? 'send-message',
                                        payload: {
                                            chatGuid: guid,
                                            message
                                        },
                                        scheduledFor: scheduledFor.getTime(),
                                        schedule: {
                                            type: 'once'
                                        }
                                    });
                                }

                                _onClose();
                            }}
                        >
                            Create
                        </Button>
                    </AlertDialogFooter>
                </AlertDialogContent>
            </AlertDialogOverlay>
        </AlertDialog>
    );
};