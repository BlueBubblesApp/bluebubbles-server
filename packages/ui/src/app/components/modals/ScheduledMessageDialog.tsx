import { ipcRenderer } from 'electron';
import React, { useEffect, useState } from 'react';
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
    RadioGroup,
    Stack,
    Radio
} from '@chakra-ui/react';
import { FocusableElement } from '@chakra-ui/utils';
import { ScheduledMessageItem } from '../tables/ScheduledMessagesTable';
import { Options, Select } from 'chakra-react-select';
import { intervalTypeOpts, scheduledMessageTypeOptions, scheduleTypeOptions } from 'app/constants';
import { useAppSelector } from 'app/hooks';


interface ScheduledMessageDialogProps {
    onCancel?: () => void;
    onCreate?: (message: ScheduledMessageItem) => void;
    onClose: () => void;
    isOpen: boolean;
    modalRef: React.RefObject<FocusableElement>;
}

const toLocalIsoString = (date: Date | null) => {
    if (!date) return '';

    const pad = (num: number) => {
        return (num < 10 ? '0' : '') + num;
    };
  
    return date.getFullYear() +
        '-' + pad(date.getMonth() + 1) +
        '-' + pad(date.getDate()) +
        'T' + pad(date.getHours()) +
        ':' + pad(date.getMinutes()) +
        ':' + pad(date.getSeconds());
};

export const ScheduledMessageDialog = ({
    onCancel,
    onCreate,
    onClose,
    isOpen,
    modalRef,
}: ScheduledMessageDialogProps): JSX.Element => {
    const usePrivateApi = useAppSelector(state => state.config.enable_private_api as boolean) ?? false;
    const [type, setType] = useState(scheduledMessageTypeOptions[0] as any | null);
    const [message, setMessage] = useState('');
    const [chatType, setChatType] = useState('dm');
    const [chatGuid, setChatGuid] = useState('');
    const [scheduledFor, setScheduledFor] = useState(null as Date | null);
    const [groups, setGroups] = useState([] as any | null);
    const [selectedGroup, setSelectedGroup] = useState(null as any | null);
    const [scheduleType, setScheduleType] = useState(scheduleTypeOptions[0] as any | null);
    const [intervalType, setIntervalType] = useState(intervalTypeOpts[0] as any | null);
    const [interval, setIntervalValue] = useState(1);
    const [messageError, setMessageError] = useState('');
    const hasMessageError = (messageError ?? '').length > 0;
    const [guidError, setGuidError] = useState('');
    const hasGuidError = (guidError ?? '').length > 0;
    const [dateError, setDateError] = useState('');
    const hasDateError = (dateError ?? '').length > 0;
    const [intervalError, setIntervalError] = useState('');
    const hasIntervalError = (intervalError ?? '').length > 0;

    useEffect(() => {
        ipcRenderer.invoke('get-chats').then((chats: any[]) => {
            chats.sort((a, b) => a.displayName && !b.displayName ? -1 : 1);
            const groups = chats.filter((e: any) => e.style === 43).map((e: any) => {
                let label = e.displayName ?? '';
                if (label.length === 0) {
                    label = e.participants.map((e: any) => e.address).join(', ');
                }
                return { label, value: e.guid };
            });
            setGroups(groups);
        });
    }, []);

    const _onClose = () => {
        setType(scheduledMessageTypeOptions[0] as any | null);
        setMessage('');
        setChatType('dm');
        setGroups([]);
        setSelectedGroup(null);
        setChatGuid('');
        setScheduledFor(null);
        setScheduleType(scheduleTypeOptions[0] as any | null);
        setIntervalType(intervalTypeOpts[0] as any | null);
        setIntervalValue(1);
        setMessageError('');
        setGuidError('');
        setIntervalError('');

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
                        <FormControl mt={5}>
                            <RadioGroup onChange={setChatType} value={chatType}>
                                <Stack direction='row'>
                                    <Radio value='dm'>Direct Message</Radio>
                                    <Radio value='group'>Group Chat</Radio>
                                </Stack>
                            </RadioGroup>
                        </FormControl>
                        {chatType === 'dm' ? (
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
                        ) : null}
                        {chatType === 'group' ? (
                            <FormControl mt={5}>
                                <FormLabel>Select Group Chat</FormLabel>
                                <Select
                                    size='md'
                                    options={groups as unknown as Options<string>}
                                    value={selectedGroup}
                                    onChange={(e) => {
                                        setSelectedGroup(e);
                                        setChatGuid((e as any).value);
                                    }}
                                />
                            </FormControl>
                        ) : null}
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
                        <FormControl mt={5}>
                            <FormLabel>Schedule Type</FormLabel>
                            <Select
                                size='md'
                                options={scheduleTypeOptions as unknown as Options<string>}
                                value={scheduleType}
                                onChange={setScheduleType}
                            />
                        </FormControl>
                        <FormControl isInvalid={hasDateError} mt={5}>
                            <FormLabel htmlFor='scheduledFor'>Scheduled For</FormLabel>
                            <Input
                                id='scheduledFor'
                                type='datetime-local'
                                defaultValue={toLocalIsoString(scheduledFor)}
                                onChange={(e) => {
                                    setDateError('');
                                    if (e.target.value.length !== 0) {
                                        let date;

                                        try {
                                            date = new Date(e.target.value);
                                        } catch (e) {
                                            setDateError('Invalid date');
                                            return;
                                        }

                                        setScheduledFor(date);
                                    }
                                }}
                            />
                            {hasDateError ? (
                                <FormErrorMessage>{dateError}</FormErrorMessage>
                            ) : null}
                        </FormControl>
                        {scheduleType.value === 'recurring' ? (
                            <>
                                <FormControl isInvalid={hasIntervalError} mt={5}>
                                    <FormLabel htmlFor='scheduleInterval'>Every</FormLabel>
                                    <Input
                                        id='scheduleInterval'
                                        type='number'
                                        value={interval ?? 1}
                                        onChange={(e) => {
                                            setIntervalValue(Number.parseInt(e.target.value));
                                        }}
                                    />
                                    {hasIntervalError ? (
                                        <FormErrorMessage>{intervalError}</FormErrorMessage>
                                    ) : null}
                                </FormControl>
                                <FormControl mt={5}>
                                    <Select
                                        size='md'
                                        options={intervalTypeOpts as unknown as Options<string>}
                                        value={intervalType}
                                        onChange={setIntervalType}
                                    />
                                </FormControl>
                            </>
                        ) : null}
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
                                if (chatGuid.length === 0) {
                                    setGuidError('Please enter a phone number or chat GUID!');
                                    return;
                                }

                                let guid = chatGuid;
                                if (chatType === 'dm' && !guid.includes(';-;')) {
                                    guid = `iMessage;-;${guid}`;
                                }

                                if (message.length === 0) {
                                    setMessageError('Please enter a message to send!');
                                    return;
                                }

                                const now = new Date();
                                if (!scheduledFor || scheduledFor < now) {
                                    setDateError('Please enter a date in the future!');
                                    return;
                                }

                                if (!interval) {
                                    setIntervalError('Please enter a valid interval!');
                                    return;
                                } else if (interval < 1) {
                                    setIntervalError('Interval must be > 0!');
                                    return;
                                }

                                if (onCreate) {
                                    onCreate({
                                        id: null,
                                        type: type?.value ?? 'send-message',
                                        payload: {
                                            chatGuid: guid,
                                            message,
                                            method: usePrivateApi ? 'private-api' : 'apple-script'
                                        },
                                        scheduledFor: scheduledFor.getTime(),
                                        schedule: {
                                            type: scheduleType.value,
                                            interval: interval ?? 1,
                                            intervalType: intervalType.value
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