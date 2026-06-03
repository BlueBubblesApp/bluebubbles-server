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
    Image,
    Switch,
    FormControl,
    FormLabel,
    NumberInput,
    NumberInputField
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
import {
    getContactsOauthUrl,
    restartOauthService,
    getGoogleContactsSyncStatus,
    googleContactsSyncNow,
    googleContactsDisconnect,
    setGoogleContactsSyncEnabled,
    setGoogleContactsSyncInterval,
    GoogleContactsStatus
} from 'app/utils/IpcUtils';
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

const getGoogleStatusColor = (status: ProgressStatus): string => {
    if (status === ProgressStatus.COMPLETED) return 'green';
    if (status === ProgressStatus.FAILED) return 'red';
    return 'yellow';
};

const getGoogleStatusText = (status: ProgressStatus): string => {
    if (status === ProgressStatus.IN_PROGRESS) return 'Syncing...';
    if (status === ProgressStatus.COMPLETED) return 'Synced';
    if (status === ProgressStatus.FAILED) return 'Failed';
    return 'Not Connected';
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

    const [syncStatus, setSyncStatus] = useState(null as GoogleContactsStatus | null);
    const [intervalInput, setIntervalInput] = useState('360');
    const [savingSync, setSavingSync] = useState(false);
    const [syncingNow, setSyncingNow] = useState(false);

    const [useOwnClient, setUseOwnClient] = useState(false);
    const [clientIdInput, setClientIdInput] = useState('');
    const [clientSecretInput, setClientSecretInput] = useState('');
    const [hasSecret, setHasSecret] = useState(false);
    const [savingClient, setSavingClient] = useState(false);

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

    const refreshSyncStatus = async (): Promise<void> => {
        const status = await getGoogleContactsSyncStatus();
        if (status) {
            setSyncStatus(status);
            setIntervalInput(String(status.interval));
        }
    };

    const onToggleSync = async (enabled: boolean): Promise<void> => {
        setSavingSync(true);
        try {
            const status = await setGoogleContactsSyncEnabled(enabled);
            if (status) setSyncStatus(status);
        } finally {
            setSavingSync(false);
        }
    };

    const onCommitInterval = async (): Promise<void> => {
        const minutes = Math.max(15, Number(intervalInput) || 360);
        const status = await setGoogleContactsSyncInterval(minutes);
        if (status) {
            setSyncStatus(status);
            setIntervalInput(String(status.interval));
        }
    };

    const onSyncNow = async (): Promise<void> => {
        setSyncingNow(true);
        try {
            await googleContactsSyncNow();
            showSuccessToast({ id: 'gc-sync', description: 'Finished syncing Google Contacts!' });
            loadContacts();
            await refreshSyncStatus();
        } catch {
            // Errors are surfaced in the server logs.
        } finally {
            setSyncingNow(false);
        }
    };

    const onDisconnectSync = async (): Promise<void> => {
        const status = await googleContactsDisconnect();
        if (status) setSyncStatus(status);
        setAuthStatus(ProgressStatus.NOT_STARTED);
    };

    const loadClientConfig = async (): Promise<void> => {
        const cfg = await ipcRenderer.invoke('get-config');
        if (cfg) {
            setUseOwnClient(!!cfg.google_contacts_use_own_client);
            setClientIdInput(cfg.google_oauth_client_id ?? '');
            setHasSecret(!!cfg.google_oauth_client_secret);
        }
    };

    const onToggleMode = async (enabled: boolean): Promise<void> => {
        setUseOwnClient(enabled);
        await ipcRenderer.invoke('set-config', { google_contacts_use_own_client: enabled });
        // Regenerate the OAuth URL so the button uses the correct flow for the mode.
        const url = await getContactsOauthUrl();
        setOauthUrl(url);
    };

    const onSaveCustomClient = async (): Promise<void> => {
        setSavingClient(true);
        try {
            const payload: NodeJS.Dict<string> = { google_oauth_client_id: clientIdInput.trim() };
            // Only overwrite the secret if a new one was entered.
            if (clientSecretInput.trim().length > 0) {
                payload.google_oauth_client_secret = clientSecretInput.trim();
            }
            await ipcRenderer.invoke('set-config', payload);

            // Regenerate the OAuth URL so it uses the newly-saved client.
            const url = await getContactsOauthUrl();
            setOauthUrl(url);

            if (payload.google_oauth_client_secret) setHasSecret(true);
            setClientSecretInput('');
            showSuccessToast({
                id: 'gc-client',
                description: 'Saved your Google OAuth client. Now click "Continue with Google".'
            });
        } finally {
            setSavingClient(false);
        }
    };

    useEffect(() => {
        loadContacts();
        refreshPermissionStatus();
        refreshSyncStatus();
        loadClientConfig();

        ipcRenderer.removeAllListeners('oauth-status');
        getContactsOauthUrl().then(url => setOauthUrl(url));

        ipcRenderer.on('oauth-status', (_: any, data: ProgressStatus) => {
            setAuthStatus(data);

            if (data === ProgressStatus.COMPLETED) {
                loadContacts(true);
                refreshSyncStatus();
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
                <Text fontSize='md' mt={2} mb={2}>
                    Add, import, refresh, or clear your local contacts.
                </Text>
                <Box>
                    <Menu>
                        <MenuButton
                            as={Button}
                            rightIcon={<BsChevronDown />}
                            width="12em"
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
                </Box>
                <Divider orientation='horizontal' mt={4} mb={4} />
                <Text fontSize='md' mb={2}>
                    Grant access to your macOS Contacts to pull richer contact details like avatars and addresses
                    from the native Address Book.
                </Text>
                <Box>
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
                        macOS Contacts: <Text as="span" color={getPermissionColor(permission)}>
                            {permission ? permission : 'Checking...'}
                        </Text>
                    </Text>
                </Box>
                <Divider orientation='horizontal' mt={4} mb={4} />
                <Text fontSize='md' mb={2}>
                    Authorize BlueBubbles to access your Google Contacts to download contacts and avatars
                    from Google, and serve them to any connected clients.
                </Text>
                <FormControl display='flex' alignItems='center' mb={2}>
                    <FormLabel htmlFor='gc-mode-toggle' mb='0' fontSize='md'>
                        Use my own Google OAuth client (enables automatic background sync)
                    </FormLabel>
                    <Switch
                        id='gc-mode-toggle'
                        isChecked={useOwnClient}
                        onChange={(e) => onToggleMode(e.target.checked)}
                    />
                </FormControl>
                {!useOwnClient ? (
                    <Text fontSize='sm' color='gray.500' mb={2}>
                        One-time import using BlueBubbles&apos; built-in Google sign-in. Quick to set up, but
                        contacts won&apos;t update automatically afterward.
                    </Text>
                ) : (
                    <Box>
                        <Text fontSize='sm' fontWeight='bold' mb={1}>
                            Step 1 — Your Google OAuth client
                        </Text>
                        <Text fontSize='sm' color='gray.500' mb={3}>
                            Background sync needs offline access, which the built-in client can&apos;t grant. In
                            Google Cloud Console: enable the People API, set up the OAuth consent screen (add
                            yourself as a test user), and create an OAuth client of type &quot;Desktop app&quot;.
                            Paste its credentials below and Save, then connect.
                        </Text>
                        <Box p={3} borderWidth='1px' borderRadius='md' mb={3}>
                            <Stack direction='row' alignItems='center' spacing={3}>
                                <Input
                                    size='sm'
                                    placeholder='Client ID'
                                    value={clientIdInput}
                                    onChange={(e) => setClientIdInput(e.target.value)}
                                />
                                <Input
                                    size='sm'
                                    type='password'
                                    placeholder={hasSecret ? '•••••••• (saved)' : 'Client Secret'}
                                    value={clientSecretInput}
                                    onChange={(e) => setClientSecretInput(e.target.value)}
                                />
                                <Button size='sm' isLoading={savingClient} onClick={() => onSaveCustomClient()}>
                                    Save
                                </Button>
                            </Stack>
                        </Box>
                    </Box>
                )}
                <Box>
                    {useOwnClient ? (
                        <Text fontSize='sm' fontWeight='bold' mb={1}>
                            Step 2 — Connect
                        </Text>
                    ) : null}
                    <Link
                        href={oauthUrl}
                        target="_blank"
                        _hover={{ textDecoration: 'none' }}
                    >
                        <Stack direction='row' alignItems='center'>
                            <Button
                                pl={10}
                                pr={10}
                                leftIcon={<Image src={GoogleIcon} mr={1} width={5} />}
                                variant='outline'
                                isDisabled={useOwnClient && !clientIdInput}
                                onClick={() => {
                                    restartOauthService();
                                }}
                            >
                                Continue with Google
                            </Button>
                            <Box pl={2}>
                                {getOauthIcon()}
                            </Box>
                            <Text as="span" verticalAlign="middle" pl={2}>
                                Google Contacts: <Text as="span" color={getGoogleStatusColor(authStatus)}>
                                    {getGoogleStatusText(authStatus)}
                                </Text>
                            </Text>
                        </Stack>
                    </Link>
                </Box>
                {useOwnClient && syncStatus?.connected ? (
                    <Box mt={3}>
                        <FormControl display='flex' alignItems='center'>
                            <FormLabel htmlFor='gc-sync-toggle' mb='0' fontSize='md'>
                                Keep contacts synced in the background
                            </FormLabel>
                            <Switch
                                id='gc-sync-toggle'
                                isChecked={syncStatus?.enabled ?? false}
                                isDisabled={savingSync}
                                onChange={(e) => onToggleSync(e.target.checked)}
                            />
                        </FormControl>
                        <Stack direction='row' alignItems='center' spacing={3} mt={3}>
                            <Text fontSize='sm'>Sync every</Text>
                            <NumberInput
                                size='sm'
                                maxW='6.5em'
                                min={15}
                                value={intervalInput}
                                onChange={(valStr) => setIntervalInput(valStr)}
                                onBlur={() => onCommitInterval()}
                            >
                                <NumberInputField />
                            </NumberInput>
                            <Text fontSize='sm'>minutes</Text>
                            <Button
                                size='sm'
                                leftIcon={<BiRefresh />}
                                isLoading={syncingNow}
                                onClick={() => onSyncNow()}
                            >
                                Sync Now
                            </Button>
                            <Button
                                size='sm'
                                variant='outline'
                                colorScheme='red'
                                onClick={() => onDisconnectSync()}
                            >
                                Disconnect
                            </Button>
                        </Stack>
                        <Text fontSize='sm' color='gray.500' mt={2}>
                            {syncStatus?.lastSync
                                ? `Last synced ${new Date(syncStatus.lastSync).toLocaleString()}`
                                : 'Not yet synced'}
                            {syncStatus?.usingCustomClient ? ' • Using your own OAuth client' : ''}
                        </Text>
                    </Box>
                ) : null}
            </Stack>
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