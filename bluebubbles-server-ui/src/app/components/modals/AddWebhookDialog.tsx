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
    FormLabel
} from '@chakra-ui/react';
import { FocusableElement } from '@chakra-ui/utils';


interface AddWebhookDialogProps {
    onCancel?: () => void;
    onConfirm?: (address: string) => void;
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
                        Enter a URL to receive a POST request callback when an event occurs
                        <br />
                        <br />
                        <FormControl isInvalid={isInvalid}>
                            <FormLabel htmlFor='url'>URL</FormLabel>
                            <Input
                                id='url'
                                type='text'
                                maxWidth="20em"
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

                                if (onConfirm) onConfirm(url);
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