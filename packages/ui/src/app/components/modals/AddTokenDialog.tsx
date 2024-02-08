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
    const [tokenExpireAt, setTokenExpireAt] = useState('');
    const dispatch = useAppDispatch();
    
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
                        <Input 
                            id="tokenExpireAt"
                            type="date"
                            value={tokenExpireAt}
                            onChange={(e) => {
                                setTokenExpireAt(e.target.value);
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
                                const date = new Date(tokenExpireAt).getTime();
                                if (existingId) {
                                    dispatch(update({ name: tokenName, password: tokenPass, expireAt: date }));
                                } else {
                                    dispatch(create({ name: tokenName, password: tokenPass, expireAt: date }));
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