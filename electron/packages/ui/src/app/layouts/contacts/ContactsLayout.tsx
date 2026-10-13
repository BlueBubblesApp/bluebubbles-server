import React, { useEffect, useRef, useState } from 'react';
import { ipcRenderer } from 'electron';
import {
    Box,
    Divider,
    Flex,
    Stack,
    Text,
    Popover,
    PopoverCloseButton,
    PopoverContent,
    PopoverHeader,
    PopoverBody,
    PopoverArrow,
    PopoverTrigger,
    useBoolean,
    CircularProgress,
    Input,
    InputGroup,
    InputLeftElement,
    Menu,
    MenuButton,
    MenuDivider,
    Button,
    MenuList,
    MenuItem,
    Spinner,
    Link,
    Image
} from '@chakra-ui/react';
import {
    Pagination,
    usePagination,
    PaginationPage,
    PaginationContainer,
    PaginationPageGroup,
} from '@ajna/pagination';
import { AiOutlineInfoCircle, AiOutlineSearch } from 'react-icons/ai';
import { BsCheckAll, BsChevronDown, BsPersonPlus, BsUnlockFill } from 'react-icons/bs';
import { BiImport, BiRefresh } from 'react-icons/bi';
import { ContactAddress, ContactItem, ContactsTable } from 'app/components/tables/ContactsTable';
import { ContactDialog } from 'app/components/modals/ContactDialog';
import { addAddressToContact, createContact, deleteContact, deleteContactAddress, deleteLocalContacts, updateContact } from 'app/actions/ContactActions';
import { FiTrash } from 'react-icons/fi';
import { ConfirmationItems, showSuccessToast } from 'app/utils/ToastUtils';
import { ConfirmationDialog } from 'app/components/modals/ConfirmationDialog';
import { waitMs } from 'app/utils/GenericUtils';
import { PaginationPreviousButton } from 'app/components/buttons/PaginationPreviousButton';
import { PaginationNextButton } from 'app/components/buttons/PaginationNextButton';
import { ProgressStatus } from 'app/types';
import { getContactsOauthUrl, restartOauthService } from 'app/utils/IpcUtils';
import GoogleIcon from '../../../images/walkthrough/google-icon.png';

const perPage = 25;

const buildIdentifier = (contact: ContactItem) => {
    return [
        contact.firstName ?? '', contact.lastName ?? '',
        (contact.phoneNumbers ?? []).map((e) => e.address.replaceAll(/[^a-zA-Z0-9_]/gi, '')).join('|'),
        (contact.emails ?? []).map((e) => e.address.replaceAll(/[^a-zA-Z0-9_]/gi, '')).join('|'),
        contact.displayName ?? ''
    ].join(' ').toLowerCase();
};

const getPermissionColor = (status: string | null): string => {
    if (!status) return 'yellow';
    if (status === 'Authorized') return 'green';
    return 'red';
};

export const ContactsLayout = (): JSX.Element => {
    const [search, setSearch] = useState('' as string);
    const [isLoading, setIsLoading] = useBoolean(true);
    const [contacts, setContacts] = useState([] as any[]);
    const [permission, setPermission] = useState((): string | null => {
        return null;
    });
    const dialogRef = useRef(null);
    const inputFile = useRef(null);
    const [dialogOpen, setDialogOpen] = useBoolean();
    const alertRef = useRef(null);
    const [requiresConfirmation, confirm] = useState((): string | null => {
        return null;
    });

    const [authStatus, setAuthStatus] = useState(ProgressStatus.NOT_STARTED);
    const [oauthUrl, setOauthUrl] = useState('');

    let filteredContacts = contacts;
    if (search && search.length > 0) {
        filteredContacts = filteredContacts.filter((c) => buildIdentifier(c).includes(search.toLowerCase()));
    }

    const {
        currentPage,
        setCurrentPage,
        pagesCount,
        pages
    } = usePagination({
        pagesCount: Math.ceil(filteredContacts.length / perPage),
        initialState: { currentPage: 1 },
    });

    const refreshPermissionStatus = async (): Promise<void> => {
        setPermission(null);
        await waitMs(500);
        ipcRenderer.invoke('contact-permission-status').then((status: string) => {
            setPermission(status);
        }).catch(() => {
            setPermission('Unknown');
        });
    };

    const requestContactPermission = async (): Promise<void> => {
        setPermission(null);
        ipcRenderer.invoke('request-contact-permission', true).then((status: string) => {
            setPermission(status);
        }).catch(() => {
            setPermission('Unknown');
        });
    };

    const loadContacts = (showToast = false, extraProps: string[] = ['contactThumbnailImage']) => {
        ipcRenderer.invoke('get-contacts', extraProps).then((contactList: any[]) => {
            setContacts(contactList.map((e: any) => { 
                // Patch the ID as a string
                e.id = String(e.id);
                return e;
            }));
            setIsLoading.off();
        }).catch(() => {
            setIsLoading.off();
        });

        if (showToast) {
            showSuccessToast({
                id: 'contacts',
                description: 'Successfully refreshed Contacts!'
            });
        }
    };

    const getOauthIcon = () => {
        if (authStatus === ProgressStatus.IN_PROGRESS) {
            return <Spinner size='md' speed='0.65s' />;
        } else if (authStatus === ProgressStatus.COMPLETED) {
            return <BsCheckAll size={24} color='green' />;
        }

        return null;
    };

    useEffect(() => {
        loadContacts();
        refreshPermissionStatus();

        ipcRenderer.removeAllListeners('oauth-status');
        getContactsOauthUrl().then(url => setOauthUrl(url));

        ipcRenderer.on('oauth-status', (_: any, data: ProgressStatus) => {
            setAuthStatus(data);

            if (data === ProgressStatus.COMPLETED) {
                loadContacts(true);
            }
        });
    }, []);

    const getEmptyContent = () => {
        const wrap = (child: JSX.Element) => {
            return (
                <section style={{marginTop: 20}}>
                    {child}
                </section>
            );
        };

        if (isLoading) {
            return wrap(<CircularProgress isIndeterminate />);
        }

        if (contacts.length === 0) {
            return wrap(<Text fontSize="md">BlueBubbles found no contacts in your Mac's Address Book!</Text>);
        }

        return null;
    };

    const filterContacts = () => {
        return filteredContacts.slice((currentPage - 1) * perPage, currentPage * perPage);
    };

    const onCreate = async (contact: ContactItem) => {
        const newContact = await createContact(
            contact.firstName,
            contact.lastName,
            {
                emails: contact.emails.map((e: NodeJS.Dict<any>) => e.address),
                phoneNumbers: contact.phoneNumbers.map((e: NodeJS.Dict<any>) => e.address)
            }
        );

        if (newContact) {
            // Patch the contact using a string ID & source type
            newContact.id = String(newContact.id);
            newContact.sourceType = 'db';

            // Patch the addresses
            (newContact as any).phoneNumbers = (newContact as any).addresses.filter((e: any) => e.type === 'phone');
            (newContact as any).emails = (newContact as any).addresses.filter((e: any) => e.type === 'email');

            setContacts([newContact, ...contacts]);
        }
    };

    const onUpdate = async (contact: NodeJS.Dict<any>) => {
        const cId = typeof(contact.id) === 'string' ? Number.parseInt(contact.id) : contact.id as number;
        const newContact = await updateContact(
            cId,
            {
                firstName: contact.firstName,
                lastName: contact.lastName,
                displayName: contact.displayName
            }
        );

        const copiedContacts = [...contacts];
        let updated = false;
        for (let i = 0; i < copiedContacts.length; i++) {
            if (copiedContacts[i].id === String(cId)) {
                copiedContacts[i].firstName = newContact.firstName;
                copiedContacts[i].lastName = newContact.lastName;
                copiedContacts[i].displayName = newContact.displayName;
                updated = true;
            }
        }

        if (updated) {
            setContacts(copiedContacts);
        }
    };

    const onDelete = async (contactId: number | string) => {
        await deleteContact(typeof(contactId) === 'string' ? Number.parseInt(contactId as string) : contactId);
        setContacts(contacts.filter((e: ContactItem) => {
            return e.id !== String(contactId);
        }));
    };

    const onAddAddress = async (contactId: number | string, address: string) => {
        const cId = typeof(contactId) === 'string' ? Number.parseInt(contactId as string) : contactId;
        const addr = await addAddressToContact(cId, address, address.includes('@') ? 'email' : 'phone');
        if (addr) {
            setContacts(contacts.map((e: ContactItem) => {
                if (e.id !== String(contactId)) return e;
                if (address.includes('@')) {
                    e.emails = [...e.emails, addr];
                } else {
                    e.phoneNumbers = [...e.phoneNumbers, addr];
                }

                return e;
            }));
        }
    };

    const onDeleteAddress = async (contactAddressId: number) => {
        await deleteContactAddress(contactAddressId);
        setContacts(contacts.map((e: ContactItem) => {
            e.emails = e.emails.filter((e: ContactAddress) => e.id !== contactAddressId);
            e.phoneNumbers = e.phoneNumbers.filter((e: ContactAddress) => e.id !== contactAddressId);
            return e;
        }));
    };

    const clearLocalContacts = async () => {
        // Delete the contacts, then filter out the DB items
        await deleteLocalContacts();
        setContacts(contacts.filter(e => e.sourceType !== 'db'));
    };

    const confirmationActions: ConfirmationItems = {
        clearLocalContacts: {
            message: (
                'Are you sure you want to clear/delete all local Contacts?<br /><br />' +
                'This will remove any Contacts added manually, via the API, or via the import process'
            ),
            func: clearLocalContacts
        }
    };

    return (
        <Box p={3} borderRadius={10}>
            <Stack direction='column' p={5}>
                <Text fontSize='2xl'>Controls</Text>
                <Divider orientation='horizontal' />
                <Box>
                    <Menu>
                        <MenuButton
                            as={Button}
                            rightIcon={<BsChevronDown />}
                            width="12em"mr={5}
                        >
                            Manage
                        </MenuButton>
                        <MenuList>
                            <MenuItem icon={<BsPersonPlus />} onClick={() => setDialogOpen.on()}>
                                Add Contact
                            </MenuItem>
                            <MenuItem icon={<BiRefresh />} onClick={() => loadContacts(true)}>
                                Refresh Contacts
                            </MenuItem>
                            <MenuItem
                                icon={<BiImport />}
                                onClick={() => {
                                    if (inputFile && inputFile.current) {
                                        (inputFile.current as HTMLElement).click();
                                    }
                                }}
                            >
                                Import VCF
                                <input
                                    type='file'
                                    id='file'
                                    ref={inputFile}
                                    accept=".vcf"
                                    style={{display: 'none'}}
                                    onChange={async (e) => {
                                        const files = e?.target?.files ?? [];
                                        for (const i of files) {
                                            await ipcRenderer.invoke('import-vcf', i.path);
                                        }

                                        loadContacts();
                                    }}
                                />
                            </MenuItem>
                            <MenuDivider />
                            <MenuItem icon={<FiTrash />} onClick={() => confirm('clearLocalContacts')}>
                                Clear Local Contacts
                            </MenuItem>
                        </MenuList>
                    </Menu>
                    <Menu>
                        <MenuButton
                            as={Button}
                            rightIcon={<BsChevronDown />}
                            width="12em"
                            mr={5}
                        >
                            Permissions
                        </MenuButton>
                        <MenuList>
                            <MenuItem icon={<BiRefresh />} onClick={() => refreshPermissionStatus()}>
                                Refresh Permission Status
                            </MenuItem>
                            {(permission !== null && permission !== 'Authorized') ? (
                                <MenuItem icon={<BsUnlockFill />} onClick={() => requestContactPermission()}>
                                    Request Permission
                                </MenuItem>
                            ) : null}
                        </MenuList>
                    </Menu>
                    <Text as="span" verticalAlign="middle">
                        Status: <Text as="span" color={getPermissionColor(permission)}>
                            {permission ? permission : 'Checking...'}
                        </Text>
                    </Text>
                </Box>
            </Stack>
            <Box ml={5} mr={5}>
                <Text fontSize='md'>
                    Using the button below, you can authorize BlueBubbles to access your Google Contacts. This will allow BlueBubbles to
                    download your contacts + avatars from Google, and serve them to any connected clients.
                </Text>
                <Link
                    href={oauthUrl}
                    target="_blank"
                    _hover={{ textDecoration: 'none' }}
                >
                    <Stack direction='row' alignItems='center'>
                        <Button
                            pl={10}
                            pr={10}
                            mt={4}
                            leftIcon={<Image src={GoogleIcon} mr={1} width={5} />}
                            variant='outline'
                            onClick={() => {
                                restartOauthService();
                            }}
                        >
                            Continue with Google
                        </Button>
                        <Box pt={3} pl={2}>
                            {getOauthIcon()}
                        </Box>
                    </Stack>
                </Link>
            </Box>
            <Stack direction='column' p={5}>
                <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                    <Text fontSize='2xl'>Contacts ({filteredContacts.length})</Text>
                    <Popover trigger='hover'>
                        <PopoverTrigger>
                            <Box ml={2} _hover={{ color: 'brand.primary', cursor: 'pointer' }}>
                                <AiOutlineInfoCircle />
                            </Box>
                        </PopoverTrigger>
                        <PopoverContent>
                            <PopoverArrow />
                            <PopoverCloseButton />
                            <PopoverHeader>Information</PopoverHeader>
                            <PopoverBody>
                                <Text>
                                    Here are the contacts on your macOS device that BlueBubbles knows about,
                                    and will serve to any clients that want to know about them. These include
                                    contacts from this Mac's Address Book, as well as contacts from uploads/imports
                                    or manual entry.
                                </Text>
                            </PopoverBody>
                        </PopoverContent>
                    </Popover>
                </Flex>
                <Divider orientation='horizontal' />
                <Flex flexDirection='row' justifyContent='flex-end' alignItems='center' pt={3}>
                    <InputGroup width="xxs">
                        <InputLeftElement pointerEvents='none'>
                            <AiOutlineSearch color='gray.300' />
                        </InputLeftElement>
                        <Input
                            placeholder='Search Contacts'
                            onChange={(e) => {
                                if (currentPage > 1) {
                                    setCurrentPage(1);
                                }

                                setSearch(e.target.value);
                            }}
                            value={search}
                        />
                    </InputGroup>
                </Flex>
                <Flex justifyContent="center" alignItems="center">
                    {getEmptyContent()}
                </Flex>
                {(contacts.length > 0) ? (
                    <ContactsTable
                        contacts={filterContacts()}
                        onCreate={onCreate}
                        onDelete={onDelete}
                        onUpdate={onUpdate}
                        onAddressAdd={onAddAddress}
                        onAddressDelete={onDeleteAddress}
                    />
                ) : null}
                <Pagination
                    pagesCount={pagesCount}
                    currentPage={currentPage}
                    onPageChange={setCurrentPage}
                >
                    <PaginationContainer
                        align="center"
                        justify="space-between"
                        w="full"
                        pt={2}
                    >
                        <PaginationPreviousButton />
                        <Box ml={1}></Box>
                        <PaginationPageGroup flexWrap="wrap" justifyContent="center">
                            {pages.map((page: number) => (
                                <PaginationPage 
                                    key={`pagination_page_${page}`} 
                                    page={page}
                                    my={1}
                                    px={3}
                                    fontSize={14}
                                    colorScheme='gray'
                                    color='black'
                                />
                            ))}
                        </PaginationPageGroup>
                        <Box ml={1}></Box>
                        <PaginationNextButton />
                    </PaginationContainer>
                </Pagination>
            </Stack>

            <ContactDialog
                modalRef={dialogRef}
                isOpen={dialogOpen}
                onCreate={onCreate}
                onDelete={onDelete}
                onAddressAdd={onAddAddress}
                onAddressDelete={onDeleteAddress}
                onClose={() => setDialogOpen.off()}
            />

            <ConfirmationDialog
                modalRef={alertRef}
                onClose={() => confirm(null)}
                body={confirmationActions[requiresConfirmation as string]?.message}
                onAccept={() => {
                    confirmationActions[requiresConfirmation as string].func();
                }}
                isOpen={requiresConfirmation !== null}
            />
        </Box>
    );
};