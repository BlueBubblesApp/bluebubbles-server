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
    FormHelperText,
    Text
} from '@chakra-ui/react';
import { Select as MultiSelect } from 'chakra-react-select';
import { ipcRenderer } from 'electron';
import { FocusableElement } from '@chakra-ui/utils';
import { webhookEventOptions } from '../../constants';
import { MultiSelectValue } from '../../types';
import { useAppDispatch, useAppSelector } from '../../hooks';
import { create, update } from '../../slices/WebhooksSlice';
import { convertMultiSelectValues } from '../../utils/GenericUtils';


interface AddWebhookDialogProps {
    onCancel?: () => void;
    isOpen: boolean;
    modalRef: React.RefObject<FocusableElement>;
    onClose: () => void;
    existingId?: number;
}


export const AddWebhookDialog = ({
    onCancel,
    isOpen,
    modalRef,
    onClose,
    existingId,
}: AddWebhookDialogProps): JSX.Element => {
    const [url, setUrl] = useState('');
    const dispatch = useAppDispatch();
    const webhooks = useAppSelector(state => state.webhookStore.webhooks) ?? [];
    const [selectedEvents, setSelectedEvents] = useState(
        webhookEventOptions.filter((option: any) => option.label === 'All Events') as Array<MultiSelectValue>);
    const [urlError, setUrlError] = useState('');
    const isUrlInvalid = (urlError ?? '').length > 0;
    const [eventsError, setEventsError] = useState('');
    const isEventsError = (eventsError ?? '').length > 0;
    const [chatOptions, setChatOptions] = useState([] as Array<MultiSelectValue>);
    const [selectedChats, setSelectedChats] = useState([] as Array<MultiSelectValue>);

    useEffect(() => {
        ipcRenderer.invoke('get-chats').then((chats: any[]) => {
            chats.sort((a, b) => {
                const aHasName = !!a.displayName;
                const bHasName = !!b.displayName;
                if (aHasName === bHasName) return 0;
                return aHasName ? -1 : 1;
            });
            const options = chats.map((e: any) => {
                let label = e.displayName ?? '';
                if (label.length === 0) {
                    label = e.participants?.map((p: any) => p.address).join(', ') ?? e.chatIdentifier ?? e.guid;
                }
                return { label, value: e.guid };
            });
            setChatOptions(options);
        });
    }, []);

    useEffect(() => {
        if (!existingId) return;

        const webhook = webhooks.find(e => e.id === existingId);
        if (webhook) {
            setUrl(webhook.url);
            setSelectedEvents(convertMultiSelectValues(JSON.parse(webhook.events)));
        }
    }, [existingId]);

    useEffect(() => {
        if (!existingId) return;

        const webhook = webhooks.find(e => e.id === existingId);
        if (webhook?.chatGuids && webhook.chatGuids.length > 0) {
            const matched = webhook.chatGuids.map(guid => {
                const option = chatOptions.find(o => o.value === guid);
                return option ?? { label: guid, value: guid };
            });
            setSelectedChats(matched);
        } else {
            setSelectedChats([]);
        }
    }, [existingId, chatOptions]);

    return (
        <AlertDialog
            isOpen={isOpen}
            leastDestructiveRef={modalRef}
            onClose={() => onClose()}
        >
            <AlertDialogOverlay>
                <AlertDialogContent>
                    <AlertDialogHeader fontSize='lg' fontWeight='bold'>
                        Add a new Webhook
                    </AlertDialogHeader>

                    <AlertDialogBody>
                        <Text>Enter a URL to receive a POST request callback when an event occurs</Text>
                        <FormControl isInvalid={isUrlInvalid} mt={5}>
                            <FormLabel htmlFor='url'>URL</FormLabel>
                            <Input
                                id='url'
                                type='text'
                                value={url}
                                placeholder='https://<your URL path>'
                                onChange={(e) => {
                                    setUrlError('');
                                    setUrl(e.target.value);
                                }}
                            />
                            {isUrlInvalid ? (
                                <FormErrorMessage>{urlError}</FormErrorMessage>
                            ) : null}
                        </FormControl>
                        <FormControl isInvalid={isEventsError} mt={5}>
                            <FormLabel htmlFor='permissions'>Event Subscriptions</FormLabel>
                            <MultiSelect
                                size='md'
                                isMulti={true}
                                options={webhookEventOptions}
                                value={selectedEvents}
                                onChange={(newValues) => {
                                    setEventsError('');
                                    setSelectedEvents(newValues as Array<MultiSelectValue>);
                                }}
                            />
                            {isEventsError ? (
                                <FormErrorMessage>{eventsError}</FormErrorMessage>
                            ) : null}
                        </FormControl>
                        <FormControl mt={5}>
                            <FormLabel>Chat Filter</FormLabel>
                            <MultiSelect
                                size='md'
                                isMulti={true}
                                options={chatOptions}
                                value={selectedChats}
                                placeholder='All Chats'
                                onChange={(newValues) => {
                                    setSelectedChats(newValues as Array<MultiSelectValue>);
                                }}
                            />
                            <FormHelperText>Select specific chats to receive events from. Leave empty for all chats.</FormHelperText>
                        </FormControl>

                    </AlertDialogBody>

                    <AlertDialogFooter>
                        <Button
                            ref={modalRef as React.LegacyRef<HTMLButtonElement> | undefined}
                            onClick={() => {
                                if (onCancel) onCancel();
                                setUrl('');
                                setSelectedChats([]);
                                onClose();
                            }}
                        >
                            Cancel
                        </Button>
                        <Button
                            ml={3}
                            bg='brand.primary'
                            ref={modalRef as React.LegacyRef<HTMLButtonElement> | undefined}
                            onClick={() => {
                                if (url.length === 0) {
                                    setUrlError('Please enter a webhook URL!');
                                    return;
                                }

                                if (selectedEvents.length === 0) {
                                    setEventsError('Please select at least 1 event to subscribe to!');
                                    return;
                                }

                                const chatGuids = selectedChats.length > 0 ? selectedChats.map(c => c.value) : undefined;

                                if (existingId) {
                                    dispatch(update({ id: existingId, url, events: selectedEvents, chatGuids: chatGuids ?? null }));
                                } else {
                                    dispatch(create({ url, events: selectedEvents, chatGuids }));
                                }

                                setUrl('');
                                setSelectedChats([]);
                                onClose();
                            }}
                        >
                            Save
                        </Button>
                    </AlertDialogFooter>
                </AlertDialogContent>
            </AlertDialogOverlay>
        </AlertDialog>
    );
};
