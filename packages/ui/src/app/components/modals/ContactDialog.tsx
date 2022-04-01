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
    Text,
    Flex,
    Tag,
    TagLabel,
    TagCloseButton,
    HStack,
    IconButton
} from '@chakra-ui/react';
import { FocusableElement } from '@chakra-ui/utils';
import { ContactAddress, ContactItem } from '../tables/ContactsTable';
import { showErrorToast } from 'app/utils/ToastUtils';
import { AiOutlinePlus } from 'react-icons/ai';


interface ContactDialogProps {
    onCancel?: () => void;
    onDelete?: (contactId: number) => void;
    onCreate?: (contact: ContactItem) => void;
    onAddressAdd?: (contactId: number, address: string) => void;
    onAddressDelete?: (contactAddressId: number) => void;
    onClose: () => void;
    isOpen: boolean;
    modalRef: React.RefObject<FocusableElement> | undefined;
    existingContact?: NodeJS.Dict<any>;
}

export const ContactDialog = ({
    onCancel,
    onDelete,
    onCreate,
    onClose,
    onAddressAdd,
    onAddressDelete,
    isOpen,
    modalRef,
    existingContact,
}: ContactDialogProps): JSX.Element => {
    const [firstName, setFirstName] = useState('');
    const [lastName, setLastName] = useState('');
    const [currentAddress, setCurrentAddress] = useState('');
    const [phones, setPhones] = useState([] as ContactAddress[]);
    const [emails, setEmails] = useState([] as ContactAddress[]);
    const [firstNameError, setFirstNameError] = useState('');
    const isNameValid = (firstNameError ?? '').length > 0;

    useEffect(() => {
        if (!existingContact) return;
        if (existingContact.firstName) setFirstName(existingContact.firstName);
        if (existingContact.lastName) setLastName(existingContact.lastName);
        if (existingContact.phoneNumbers) setPhones(existingContact.phoneNumbers);
        if (existingContact.emails) setEmails(existingContact.emails);
    }, [existingContact]);

    const addAddress = (address: string) => {
        const existsPhone = phones.map((e: ContactAddress) => e.address).includes(address);
        const existsEmail = emails.map((e: ContactAddress) => e.address).includes(address);
        if (existsPhone || existsEmail) {
            return showErrorToast({
                id: 'contacts',
                description: 'Address already exists!'
            });
        }

        if (address.includes('@')) {
            setEmails([{ address }, ...emails]);
        } else {
            setPhones([{ address }, ...phones]);
        }

        if (onAddressAdd && existingContact) {
            onAddressAdd(existingContact.id, address);
        }
    };

    const removeAddress = (address: string, addressId: number | null) => {
        if (address.includes('@')) {
            setEmails(emails.filter((e: NodeJS.Dict<any>) => e.address !== address));
        } else {
            setPhones(phones.filter((e: NodeJS.Dict<any>) => e.address !== address));
        }

        if (onAddressDelete && addressId) {
            onAddressDelete(addressId);
        }
    };

    const _onClose = () => {
        setPhones([]);
        setEmails([]);
        setFirstName('');
        setLastName('');
        setCurrentAddress('');

        if (onClose) onClose();
    };

    return (
        <AlertDialog
            isOpen={isOpen}
            leastDestructiveRef={modalRef}
            onClose={() => onClose()}
        >
            <AlertDialogOverlay>
                <AlertDialogContent>
                    <AlertDialogHeader fontSize='lg' fontWeight='bold'>
                        {(existingContact) ? 'Edit Contact' : 'Add a new Contact'}
                    </AlertDialogHeader>

                    <AlertDialogBody>
                        <Text>Add a custom contact to the server's database</Text>
                        <FormControl isInvalid={isNameValid} mt={5}>
                            <FormLabel htmlFor='firstName'>First Name</FormLabel>
                            <Input
                                id='firstName'
                                type='text'
                                value={firstName}
                                placeholder='Tim'
                                onChange={(e) => {
                                    setFirstNameError('');
                                    setFirstName(e.target.value);
                                }}
                            />
                            {isNameValid ? (
                                <FormErrorMessage>{firstNameError}</FormErrorMessage>
                            ) : null}
                        </FormControl>
                        <FormControl mt={5}>
                            <FormLabel htmlFor='lastName'>Last Name</FormLabel>
                            <Input
                                id='lastName'
                                type='text'
                                value={lastName}
                                placeholder='Apple'
                                onChange={(e) => {
                                    setLastName(e.target.value);
                                }}
                            />
                        </FormControl>
                        <FormControl mt={5}>
                            <FormLabel htmlFor='address'>Addresses</FormLabel>
                            <HStack>
                                <Input
                                    id='address'
                                    type='text'
                                    value={currentAddress}
                                    placeholder='Add Address'
                                    onChange={(e) => {
                                        setCurrentAddress(e.target.value);
                                    }}
                                />
                                <IconButton
                                    onClick={() => {
                                        if (!currentAddress || currentAddress.length === 0) return;
                                        addAddress(currentAddress);
                                        setCurrentAddress('');
                                    }}
                                    aria-label='Add'
                                    icon={<AiOutlinePlus />}
                                />
                            </HStack>
                            <Flex flexDirection="row" alignItems="center" justifyContent="flex-start" flexWrap="wrap" mt={2}>
                                {[...phones, ...emails].map(((e: ContactAddress) => {
                                    return (
                                        <Tag
                                            mt={1}
                                            mx={1}
                                            size={'md'}
                                            key={e.address}
                                            borderRadius='full'
                                            variant='solid'
                                        >
                                            <TagLabel>{e.address}</TagLabel>
                                            <TagCloseButton
                                                onClick={() => {
                                                    removeAddress(e.address, (e.id) ? e.id : null);
                                                }}
                                            />
                                        </Tag>
                                    );
                                }))}
                            </Flex>
                        </FormControl>
                    </AlertDialogBody>

                    <AlertDialogFooter>
                        <Button
                            ref={modalRef as React.LegacyRef<HTMLButtonElement> | undefined}
                            onClick={() => {
                                if (!existingContact && onCancel) onCancel();
                                _onClose();
                            }}
                        >
                            {(existingContact) ? 'Save & Close' : 'Cancel'}
                        </Button>
                        {(existingContact) ? (
                            <Button
                                ml={3}
                                bg='red'
                                ref={modalRef as React.LegacyRef<HTMLButtonElement> | undefined}
                                onClick={() => {
                                    if (onDelete) {
                                        onDelete(Number.parseInt(existingContact.id));
                                    }

                                    _onClose();
                                }}
                            >
                                Delete
                            </Button>
                        ) : null}
                        {(!existingContact) ? (
                            <Button
                                ml={3}
                                bg='brand.primary'
                                ref={modalRef as React.LegacyRef<HTMLButtonElement> | undefined}
                                onClick={() => {
                                    if (firstName.length === 0) {
                                        setFirstNameError('Please enter a first name for the contact!');
                                        return;
                                    }

                                    if (onCreate) {
                                        onCreate({
                                            firstName,
                                            lastName,
                                            phoneNumbers: phones,
                                            emails: emails,
                                            nickname: '',
                                            birthday: '',
                                            avatar: '',
                                            id: '',
                                            sourceType: 'db'
                                        });
                                    }

                                    _onClose();
                                }}
                            >
                                Create
                            </Button>
                        ) : null}
                    </AlertDialogFooter>
                </AlertDialogContent>
            </AlertDialogOverlay>
        </AlertDialog>
    );
};