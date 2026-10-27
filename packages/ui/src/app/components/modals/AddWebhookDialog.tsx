import React, { useEffect, useState } from 'react';
import {
    AlertDialog,
    AlertDialogOverlay,
    AlertDialogBody,
    AlertDialogContent,
    AlertDialogFooter,
    AlertDialogHeader,
    Button,
    Checkbox,
    Input,
    FormControl,
    FormErrorMessage,
    FormHelperText,
    FormLabel,
    Stack,
    Text
} from '@chakra-ui/react';
import { Select as MultiSelect } from 'chakra-react-select';
import { FocusableElement } from '@chakra-ui/utils';
import { webhookEventOptions } from '../../constants';
import { MultiSelectValue } from '../../types';
import { useAppDispatch, useAppSelector } from '../../hooks';
import { create, update } from '../../slices/WebhooksSlice';
import { convertMultiSelectValues } from '../../utils/GenericUtils';
import { WebhookSecurityOptions } from '../../utils/IpcUtils';

const defaultSecurityOptions: WebhookSecurityOptions = {
    blockPrivateAddresses: false,
    requireHttps: false,
    followRedirects: false
};


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
    const [securityOptions, setSecurityOptions] = useState<WebhookSecurityOptions>(defaultSecurityOptions);

    const setSecurityOption = (key: keyof WebhookSecurityOptions, value: boolean) => {
        setSecurityOptions(prev => ({ ...prev, [key]: value }));
    };

    const reset = () => {
        setUrl('');
        setSecurityOptions(defaultSecurityOptions);
    };

    useEffect(() => {
        if (!existingId) return;

        const webhook = webhooks.find(e => e.id === existingId);
        if (webhook) {
            setUrl(webhook.url);
            setSelectedEvents(convertMultiSelectValues(JSON.parse(webhook.events)));
            setSecurityOptions({
                blockPrivateAddresses: !!webhook.blockPrivateAddresses,
                requireHttps: !!webhook.requireHttps,
                followRedirects: !!webhook.followRedirects
            });
        }
    }, [existingId]);

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
                            <FormLabel>Security</FormLabel>
                            <Stack spacing={1}>
                                <Checkbox
                                    id='blockPrivateAddresses'
                                    isChecked={securityOptions.blockPrivateAddresses}
                                    onChange={(e) => setSecurityOption('blockPrivateAddresses', e.target.checked)}
                                >
                                    Block local network addresses
                                </Checkbox>
                                <Checkbox
                                    id='requireHttps'
                                    isChecked={securityOptions.requireHttps}
                                    onChange={(e) => setSecurityOption('requireHttps', e.target.checked)}
                                >
                                    Require HTTPS
                                </Checkbox>
                                <Checkbox
                                    id='followRedirects'
                                    isChecked={securityOptions.followRedirects}
                                    onChange={(e) => setSecurityOption('followRedirects', e.target.checked)}
                                >
                                    Follow redirects
                                </Checkbox>
                            </Stack>
                            <FormHelperText>
                                Blocking local network addresses refuses to deliver to localhost, private (LAN),
                                link-local and other non-public IPs, checked every time an event is sent. Leave it
                                off if this webhook points at something on your own network. Redirects are only
                                followed when enabled, and every hop is held to the same rules.
                            </FormHelperText>
                        </FormControl>
                    </AlertDialogBody>

                    <AlertDialogFooter>
                        <Button
                            ref={modalRef as React.LegacyRef<HTMLButtonElement> | undefined}
                            onClick={() => {
                                if (onCancel) onCancel();
                                reset();
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

                                if (existingId) {
                                    dispatch(update({
                                        id: existingId,
                                        url,
                                        events: selectedEvents,
                                        options: securityOptions
                                    }));
                                } else {
                                    dispatch(create({ url, events: selectedEvents, options: securityOptions }));
                                }

                                reset();
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