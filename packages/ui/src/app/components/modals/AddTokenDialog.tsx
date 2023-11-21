import React, { useState } from 'react';
import { FocusableElement } from '@chakra-ui/utils';
import {
    AlertDialog,
    AlertDialogOverlay,
    AlertDialogBody,
    AlertDialogContent,
    AlertDialogFooter,
    AlertDialogHeader,
    Button,
    Input,
    Text
} from '@chakra-ui/react';
import { tokenEventOptions } from '../../constants';
import { MultiSelectValue } from '../../types';
import { useAppDispatch } from '../../hooks';
import { create, update } from '../../slices/TokenSlice';

interface AddTokenDialogProps {
    onCancel?: () => void;
    isOpen: boolean;
    modalRef: React.RefObject<FocusableElement>;
    onClose: () => void;
    existingId?: number;
}

export const AddTokenDialog = ({
    onCancel,
    isOpen,
    modalRef,
    onClose,
    existingId,
}: AddTokenDialogProps): JSX.Element => {
    const [tokenName, setTokenName] = useState('');
    const [tokenPass, setTokenPass] = useState('');
    const dispatch = useAppDispatch();
    const [selectedEvents] = useState(tokenEventOptions.filter((option: any) => option.label === 'All Events') as Array<MultiSelectValue>);
    
    return(
        <AlertDialog
            isOpen={isOpen}
            leastDestructiveRef={modalRef}
            onClose={() => onClose()}
        >
            <AlertDialogOverlay>
                <AlertDialogContent>
                    <AlertDialogHeader fontSize='lg' fontWeight='bold'>
                        Add a new token
                    </AlertDialogHeader>
                    <AlertDialogBody>
                        <Text>Enter the token name</Text>
                        <Input
                            id='tokenName'
                            type='text'
                            value={tokenName}
                            placeholder='Your Token Name'
                            onChange={(e) => {
                                setTokenName(e.target.value);
                            }}
                        />
                        <Input
                            id='tokenPass'
                            type='password'
                            value={tokenPass}
                            placeholder='*******'
                            onChange={(e) => {
                                setTokenPass(e.target.value);
                            }}
                        />
                    </AlertDialogBody>
                    <AlertDialogFooter>
                        <Button
                            ref={modalRef as React.LegacyRef<HTMLButtonElement> | undefined}
                            onDoubleClick={() => {
                                if (onCancel) onCancel();
                                setTokenName('');
                                setTokenPass('');
                                onClose();
                            }} >
                                Cancel
                        </Button>
                        <Button
                            ml={3}
                            bg='brand.primary'
                            ref={modalRef as React.LegacyRef<HTMLButtonElement> | undefined}
                            onClick={() => {
                                if (tokenName.length == 0) {
                                    return;
                                }
                                if (tokenPass.length == 0) {
                                    return;
                                }
                                if (existingId) {
                                    dispatch(update({ name: tokenName, password: tokenPass, events: selectedEvents }));
                                } else {
                                    dispatch(create({ name: tokenName, password: tokenPass, events: selectedEvents }));
                                }

                                setTokenName('');
                                setTokenPass('');
                                onClose();
                            }}>
                                Save
                        </Button>
                    </AlertDialogFooter>
                </AlertDialogContent>
            </AlertDialogOverlay>
        </AlertDialog>
    );
};