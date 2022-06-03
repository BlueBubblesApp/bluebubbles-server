import React from 'react';
import {
    AlertDialog,
    AlertDialogOverlay,
    AlertDialogBody,
    AlertDialogContent,
    AlertDialogFooter,
    AlertDialogHeader,
    Button,
    ListItem,
    UnorderedList
} from '@chakra-ui/react';
import { FocusableElement } from '@chakra-ui/utils';

export type ErrorItem = {
    id: string,
    message: string
};

interface ErrorDialogProps {
    title?: string;
    errorsPrefix?: string;
    errors: Array<ErrorItem>;
    closeButtonText?: string;
    isOpen: boolean;
    modalRef: React.RefObject<FocusableElement>;
    onClose: () => void
}

export const ErrorDialog = ({
    title = 'Error!',
    errorsPrefix = 'The following errors have occurred:',
    errors,
    closeButtonText = 'Close',
    isOpen,
    modalRef,
    onClose
}: ErrorDialogProps): JSX.Element => {
    return (
        <AlertDialog
            isOpen={isOpen}
            leastDestructiveRef={modalRef}
            onClose={() => onClose()}
        >
            <AlertDialogOverlay>
                <AlertDialogContent>
                    <AlertDialogHeader fontSize='lg' fontWeight='bold'>
                        {title}
                    </AlertDialogHeader>

                    <AlertDialogBody>
                        {errorsPrefix}
                        <br />
                        <br />
                        <UnorderedList>
                            {errors.map(e => {
                                return <ListItem key={e.id}>{e.message}</ListItem>;
                            })}
                        </UnorderedList>
                        
                    </AlertDialogBody>

                    <AlertDialogFooter>
                        <Button
                            ref={modalRef as React.LegacyRef<HTMLButtonElement> | undefined}
                            onClick={() => onClose()}
                        >
                            {closeButtonText}
                        </Button>
                    </AlertDialogFooter>
                </AlertDialogContent>
            </AlertDialogOverlay>
        </AlertDialog>
    );
};