import React from 'react';
import {
    AlertDialog,
    AlertDialogOverlay,
    AlertDialogBody,
    AlertDialogContent,
    AlertDialogFooter,
    AlertDialogHeader,
    Button
} from '@chakra-ui/react';
import { FocusableElement } from '@chakra-ui/utils';


interface ConfirmationDialogProps {
    title?: string;
    body?: string;
    declineText?: string | null;
    onDecline?: () => void;
    acceptText?: string;
    onAccept?: () => void;
    isOpen: boolean;
    modalRef: React.RefObject<FocusableElement>;
    onClose: () => void;
}

const mapText = (text: string): JSX.Element[] => {
    const textSplit = text.split('<br />');
    return textSplit.map((e: string) => {
        return (
            <span key={e}>
                {e}
                <br />
            </span>
        );
    });
};

export const ConfirmationDialog = ({
    title = 'Are you sure?',
    body = 'Are you sure you want to perform this action?',
    declineText = 'No',
    acceptText = 'Yes',
    onDecline,
    onAccept,
    isOpen,
    modalRef,
    onClose
}: ConfirmationDialogProps): JSX.Element => {
    const bodyTxt = mapText(body);
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
                        {bodyTxt}
                    </AlertDialogBody>

                    <AlertDialogFooter>
                        {declineText ? (
                            <Button
                                ref={modalRef as React.LegacyRef<HTMLButtonElement> | undefined}
                                onClick={() => {
                                    if (onDecline) onDecline();
                                    onClose();
                                }}
                            >
                                {declineText}
                            </Button>
                        ): null}
                        <Button
                            ml={3}
                            colorScheme='red'
                            ref={modalRef as React.LegacyRef<HTMLButtonElement> | undefined}
                            onClick={() => {
                                if (onAccept) onAccept();
                                onClose();
                            }}
                        >
                            {acceptText}
                        </Button>
                    </AlertDialogFooter>
                </AlertDialogContent>
            </AlertDialogOverlay>
        </AlertDialog>
    );
};