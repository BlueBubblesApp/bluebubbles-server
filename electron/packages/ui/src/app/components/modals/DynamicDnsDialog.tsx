import React, { useState } from 'react';
import {
    AlertDialog,
    AlertDialogOverlay,
    AlertDialogBody,
    AlertDialogContent,
    AlertDialogFooter,
    AlertDialogHeader,
    Button,
    UnorderedList,
    ListItem,
    Input,
    FormControl,
    FormErrorMessage,
    FormLabel,
    Text
} from '@chakra-ui/react';
import { FocusableElement } from '@chakra-ui/utils';


interface DynamicDnsDialogProps {
    onCancel?: () => void;
    onConfirm?: (address: string) => void;
    isOpen: boolean;
    modalRef: React.RefObject<FocusableElement>;
    onClose: () => void;
    port?: number
}

export const DynamicDnsDialog = ({
    onCancel,
    onConfirm,
    isOpen,
    modalRef,
    onClose,
    port = 1234
}: DynamicDnsDialogProps): JSX.Element => {
    const [address, setAddress] = useState('');
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
                        Set Dynamic DNS / Custom URL
                    </AlertDialogHeader>

                    <AlertDialogBody>
                        <Text>Enter your Dynamic DNS or Custom URL, including the schema and port. Here are some examples:</Text>
                        <br />
                        <UnorderedList>
                            <ListItem>http://thequickbrownfox.ddns.net:{port}</ListItem>
                            <ListItem>http://bluebubbles.no-ip.org:{port}</ListItem>
                        </UnorderedList>
                        <br />
                        <Text>If you plan to use your own custom certificate, please remember to use <strong>"https://"</strong> as your URL scheme</Text>
                        <br />
                        <FormControl isInvalid={isInvalid}>
                            <FormLabel htmlFor='address'>Dynamic DNS / Custom URL</FormLabel>
                            <Input
                                id='address'
                                type='text'
                                maxWidth="20em"
                                value={address}
                                placeholder={`http://<your DNS>:${port}`}
                                onChange={(e) => {
                                    setError('');
                                    setAddress(e.target.value);
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
                                if (address.length === 0) {
                                    setError('Please enter a Dynamic DNS address!');
                                    return;
                                } else if (!address.startsWith('http://') && !address.startsWith('https://')) {
                                    setError('Please enter a valid Dynamic DNS URL (including http:// or https://)!');
                                    return;
                                }
                                

                                if (onConfirm) onConfirm(address);
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