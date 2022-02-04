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
    Text
} from '@chakra-ui/react';
import { Select as MultiSelect } from 'chakra-react-select';
import { FocusableElement } from '@chakra-ui/utils';
import { webhookEventOptions } from '../../constants';
import { MultiSelectValue } from '../../types';


interface AddWebhookDialogProps {
    onCancel?: () => void;
    onConfirm?: (url: string, events: Array<MultiSelectValue>) => void;
    isOpen: boolean;
    modalRef: React.RefObject<FocusableElement> | undefined;
    onClose: () => void;
}



export const AddWebhookDialog = ({
    onCancel,
    onConfirm,
    isOpen,
    modalRef,
    onClose
}: AddWebhookDialogProps): JSX.Element => {
    const [url, setUrl] = useState('');
    const [selectedEvents, setSelectedEvents] = useState(
        webhookEventOptions.filter((option: any) => option.label === 'All Events') as Array<MultiSelectValue>);
    const [error, setError] = useState('');
    const isInvalid = (error ?? '').length > 0;

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
                        <FormControl isInvalid={isInvalid} mt={5}>
                            <FormLabel htmlFor='url'>URL</FormLabel>
                            <Input
                                id='url'
                                type='text'
                                value={url}
                                placeholder='https://<your URL path>'
                                onChange={(e) => {
                                    setError('');
                                    setUrl(e.target.value);
                                }}
                            />
                            {isInvalid ? (
                                <FormErrorMessage>{error}</FormErrorMessage>
                            ) : null}
                        </FormControl>
                        <FormControl isInvalid={isInvalid} mt={5}>
                            <FormLabel htmlFor='permissions'>Events</FormLabel>
                            <MultiSelect
                                size='md'
                                isMulti={true}
                                options={webhookEventOptions}
                                value={selectedEvents}
                                onChange={(newValues) => setSelectedEvents(newValues as Array<MultiSelectValue>)}
                            />
                        </FormControl>
                        
                    </AlertDialogBody>

                    <AlertDialogFooter>
                        <Button
                            ref={modalRef as React.LegacyRef<HTMLButtonElement> | undefined}
                            onClick={() => {
                                if (onCancel) onCancel();
                                setUrl('');
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
                                    setError('Please enter a webhook URL!');
                                    return;
                                }

                                if (onConfirm) onConfirm(url, selectedEvents);
                                setUrl('');
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