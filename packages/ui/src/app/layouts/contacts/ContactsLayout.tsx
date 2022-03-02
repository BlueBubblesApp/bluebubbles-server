import React, { useEffect, useState } from 'react';
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
    InputLeftElement
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
import { AiOutlineInfoCircle, AiOutlineSearch} from 'react-icons/ai';
import { ContactItem, ContactsTable } from 'app/components/tables/ContactsTable';

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
            setContacts(contactList);
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

    return (
        <Box p={3} borderRadius={10}>
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
                            onChange={(e) => setSearch(e.target.value)}
                            value={search}
                        />
                    </InputGroup>
                </Flex>
                <Flex justifyContent="center" alignItems="center">
                    {getEmptyContent()}
                </Flex>
                {(contacts.length > 0) ? (
                    <ContactsTable contacts={filterContacts()} />
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
        </Box>
    );
};