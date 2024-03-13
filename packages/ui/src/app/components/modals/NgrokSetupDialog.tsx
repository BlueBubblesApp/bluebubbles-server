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
import { useAppSelector } from '../../hooks';
import { FocusableElement } from '@chakra-ui/utils';
import { NgrokSubdomainField } from '../fields/NgrokSubdomainField';


interface NgrokSetupDialogProps {
    onCancel?: () => void;
    onConfirm?: (address: string) => void;
    isOpen: boolean;
    modalRef: React.RefObject<FocusableElement>;
    onClose: () => void;
}

export const NgrokSetupDialog = ({
    onCancel,
    onConfirm,
    isOpen,
    modalRef,
    onClose,
}: NgrokSetupDialogProps): JSX.Element => {
    const ngrokToken: string = (useAppSelector(state => state.config.ngrok_key) ?? '');
    const [authToken, setAuthToken] = useState(ngrokToken);
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
                        Setup Ngrok
                    </AlertDialogHeader>

                    <AlertDialogBody>
                        <Text>In order to use Ngrok, you must create a <i>free</i> account and generate an auth token.</Text>
                        <br />
                        <Text>
                            If you have not done so yet, sign up for an account <u><a href="https://dashboard.ngrok.com/signup" target="_blank" rel="noreferrer">here</a></u>
                        </Text>
                        <br />
                        <Text>
                            Once you have signed up copy your auth token from your Ngrok dashboard <u><a href="https://dashboard.ngrok.com/get-started/your-authtoken" target="_blank" rel="noreferrer">here</a></u>.
                            Then paste it in the field below.
                        </Text>
                        <br />
                        <FormControl isInvalid={isInvalid}>
                            <FormLabel htmlFor='address'>Ngrok Auth Token</FormLabel>
                            <Input
                                id='ngrok_key'
                                type='password'
                                maxWidth="20em"
                                value={authToken}
                                onChange={(e) => {
                                    setError('');
                                    setAuthToken(e.target.value);
                                }}
                            />
                            {isInvalid ? (
                                <FormErrorMessage>{error}</FormErrorMessage>
                            ) : null}
                        </FormControl>
                        <br />
                        <Text>
                            If you have reserved a custom subdomain, enter it below.
                        </Text>
                        <br />
                        <NgrokSubdomainField />
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
                                if (authToken.length === 0) {
                                    setError('Please enter an Auth Token!');
                                    return;
                                }
                                

                                if (onConfirm) onConfirm(authToken);
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