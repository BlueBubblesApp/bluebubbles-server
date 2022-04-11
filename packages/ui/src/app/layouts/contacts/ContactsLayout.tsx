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
    Button,
    MenuList,
    MenuItem
} from '@chakra-ui/react';
import {
    Pagination,
    usePagination,
    PaginationNext,
    PaginationPage,
    PaginationPrevious,
    PaginationContainer,
    PaginationPageGroup,
} from '@ajna/pagination';
import { AiOutlineInfoCircle, AiOutlineSearch } from 'react-icons/ai';
import { BsChevronDown, BsPersonPlus } from 'react-icons/bs';
import { BiImport } from 'react-icons/bi';
import { ContactAddress, ContactItem, ContactsTable } from 'app/components/tables/ContactsTable';
import { ContactDialog } from 'app/components/modals/ContactDialog';
import { addAddressToContact, createContact, deleteContact, deleteContactAddress } from 'app/actions/ContactActions';

const perPage = 25;

const buildIdentifier = (contact: ContactItem) => {
    return [
        contact.firstName ?? '', contact.lastName ?? '',
        (contact.phoneNumbers ?? []).map((e) => e.address.replaceAll(/[^a-zA-Z0-9_]/gi, '')).join('|'),
        (contact.emails ?? []).map((e) => e.address.replaceAll(/[^a-zA-Z0-9_]/gi, '')).join('|'),
        contact.nickname ?? ''
    ].join(' ').toLowerCase();
};

export const ContactsLayout = (): JSX.Element => {
    const [search, setSearch] = useState('' as string);
    const [isLoading, setIsLoading] = useBoolean(true);
    const [contacts, setContacts] = useState([] as any[]);
    const dialogRef = useRef(null);
    const inputFile = useRef(null);
    const [dialogOpen, setDialogOpen] = useBoolean();

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

    useEffect(() => {
        ipcRenderer.invoke('get-contacts').then((contactList) => {
            setContacts(contactList.map((e: any) => {
                // Patch the ID as a string
                e.id = String(e.id);
                return e;
            }));
            setIsLoading.off();
        }).catch(() => {
            setIsLoading.off();
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
            // Patch the contact using a string ID
            newContact.id = String(newContact.id);

            // Patch the addresses
            (newContact as any).phoneNumbers = (newContact as any).addresses.filter((e: any) => e.type === 'phone');
            (newContact as any).emails = (newContact as any).addresses.filter((e: any) => e.type === 'email');

            setContacts([newContact, ...contacts]);
        }
    };

    const onDelete = async (contactId: number) => {
        await deleteContact(contactId);
        setContacts(contacts.filter((e: ContactItem) => {
            return e.id !== String(contactId);
        }));
    };

    const onAddAddress = async (contactId: number, address: string) => {
        const addr = await addAddressToContact(contactId, address, address.includes('@') ? 'email' : 'phone');
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
                                    onChange={(e) => {
                                        const files = e?.target?.files ?? [];
                                        for (const i of files) {
                                            ipcRenderer.invoke('import-vcf', i.path);
                                        }
                                    }}
                                />
                            </MenuItem>
                        </MenuList>
                    </Menu>
                </Box>
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
                                    and will serve to any clients that want to know about them. These are loaded
                                    directly from this Mac's Address Book. This list will not contains contacts exported
                                    from your Android device (yet).
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
                        <PaginationPrevious>Previous</PaginationPrevious>
                        <PaginationPageGroup flexWrap="wrap" justifyContent="center">
                            {pages.map((page: number) => (
                                <PaginationPage 
                                    key={`pagination_page_${page}`} 
                                    page={page}
                                    my={1}
                                />
                            ))}
                        </PaginationPageGroup>
                        <PaginationNext>Next</PaginationNext>
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
        </Box>
    );
};