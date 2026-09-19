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
    Menu,
    MenuButton,
    MenuDivider,
    Button,
    MenuList,
    MenuItem
} from '@chakra-ui/react';
import {
    Pagination,
    usePagination,
    PaginationPage,
    PaginationContainer,
    PaginationPageGroup,
} from '@ajna/pagination';
import { AiOutlineInfoCircle } from 'react-icons/ai';
import { BsChevronDown } from 'react-icons/bs';
import { AiOutlinePlus } from 'react-icons/ai';
import { BiRefresh } from 'react-icons/bi';
import { FiTrash } from 'react-icons/fi';
import { ConfirmationItems, showErrorToast, showSuccessToast } from 'app/utils/ToastUtils';
import { ConfirmationDialog } from 'app/components/modals/ConfirmationDialog';
import { ScheduledMessageDialog } from 'app/components/modals/ScheduledMessageDialog';
import { ScheduledMessageItem, ScheduledMessagesTable } from 'app/components/tables/ScheduledMessagesTable';
import { createScheduledMessage, deleteScheduledMessage, deleteScheduledMessages } from 'app/utils/IpcUtils';
import { PaginationPreviousButton } from 'app/components/buttons/PaginationPreviousButton';
import { PaginationNextButton } from 'app/components/buttons/PaginationNextButton';

const perPage = 25;

const normalizeMessage = (message: any) => {
    // Patch the ID as a string
    if (message.id) {
        message.id = String(message.id);
    }

    message.scheduledFor = message.scheduledFor?.getTime();
    message.sentAt = message.sentAt?.getTime() ?? null;
    return message;
};

export const ScheduledMessagesLayout = (): JSX.Element => {
    const [isLoading, setIsLoading] = useBoolean(true);
    const [messages, setMessages] = useState([] as any[]);
    const dialogRef = useRef(null);
    const [dialogOpen, setDialogOpen] = useBoolean();
    const alertRef = useRef(null);
    const [requiresConfirmation, confirm] = useState((): string | null => {
        return null;
    });

    const {
        currentPage,
        setCurrentPage,
        pagesCount,
        pages
    } = usePagination({
        pagesCount: Math.ceil(messages.length / perPage),
        initialState: { currentPage: 1 },
    });

    const loadMessages = (showToast = false) => {
        ipcRenderer.invoke('get-scheduled-messages').then((msgList: any[]) => {
            setMessages(msgList.map(normalizeMessage));
            setIsLoading.off();
        }).catch(() => {
            setIsLoading.off();
        });

        if (showToast) {
            showSuccessToast({
                id: 'scheduledMessages',
                description: 'Successfully refreshed Scheduled Messages!'
            });
        }
    };

    useEffect(() => {
        loadMessages();

        ipcRenderer.on('scheduled-message-update', () => {
            loadMessages();
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

        if (messages.length === 0) {
            return wrap(<Text fontSize="md">You have not scheduled any messages</Text>);
        }

        return null;
    };

    const filteredMessages = () => {
        messages.sort((a: any, b: any) => (a?.created ?? new Date()) < (b?.created ?? new Date()) ? 1 : -1);
        return messages.slice((currentPage - 1) * perPage, currentPage * perPage);
    };

    const onCreate = async (message: ScheduledMessageItem) => {
        try {
            const newScheduledMessage = await createScheduledMessage(message);
            // We need to do this so it's a JSON obj, not a class object
            const msg = JSON.parse(JSON.stringify(normalizeMessage(newScheduledMessage)));
            setMessages([msg, ...messages]);
            showSuccessToast({ description: 'Successfully created Scheduled message!' });
        } catch (ex: any) {
            showErrorToast({ description: `Failed to create Scheduled Message! ${ex?.message}` });
        }
        
    };

    const onDelete = async (msgId: number | string) => {
        try {
            await deleteScheduledMessage(typeof(msgId) === 'string' ? Number.parseInt(msgId as string) : msgId);
            setMessages(messages.filter((e: ScheduledMessageItem) => {
                return e.id !== String(msgId);
            }));
            showSuccessToast({ description: 'Successfully deleted Scheduled message!' });
        } catch (ex: any) {
            showErrorToast({ description: `Failed to delete Scheduled Message! ${ex?.message}` });
        }
    };

    const clearScheduledMessages = async () => {
        try {
            // Delete the scheduled messages
            await deleteScheduledMessages();
            setMessages([]);
            showSuccessToast({ description: 'Successfully deleted all Scheduled messages!' });
        } catch (ex: any) {
            showErrorToast({ description: `Failed to delete Scheduled Messages! ${ex?.message}` });
        }
    };

    const confirmationActions: ConfirmationItems = {
        clearScheduledMessages: {
            message: ('Are you sure you want to clear/delete all your scheduled messages?'),
            func: clearScheduledMessages
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
                            <MenuItem icon={<AiOutlinePlus />} onClick={() => setDialogOpen.on()}>
                                Create New
                            </MenuItem>
                            <MenuItem icon={<BiRefresh />} onClick={() => loadMessages(true)}>
                                Refresh List
                            </MenuItem>
                            <MenuDivider />
                            <MenuItem icon={<FiTrash />} onClick={() => confirm('clearScheduledMessages')}>
                                Delete All
                            </MenuItem>
                        </MenuList>
                    </Menu>
                </Box>
            </Stack>
            <Stack direction='column' p={5}>
                <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                    <Text fontSize='2xl'>Scheduled Messages ({messages.length})</Text>
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
                                    These are your scheduled messages. They are messages that are scheduled
                                    to be sent at a later date. You can create a scheduled message by clicking
                                    the Manage dropdown and selecting `Create Scheduled Message`. All of your
                                    connected devices will be able to schedule messages, and they will show up
                                    here to be fulfilled by the server.
                                </Text>
                            </PopoverBody>
                        </PopoverContent>
                    </Popover>
                </Flex>
                <Divider orientation='horizontal' />
                <Flex justifyContent="center" alignItems="center">
                    {getEmptyContent()}
                </Flex>
                {(messages.length > 0) ? (
                    <ScheduledMessagesTable
                        messages={filteredMessages()}
                        onDelete={onDelete}
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
                                />
                            ))}
                        </PaginationPageGroup>
                        <Box ml={1}></Box>
                        <PaginationNextButton />
                    </PaginationContainer>
                </Pagination>
            </Stack>

            <ConfirmationDialog
                modalRef={alertRef}
                onClose={() => confirm(null)}
                body={confirmationActions[requiresConfirmation as string]?.message}
                onAccept={() => {
                    confirmationActions[requiresConfirmation as string].func();
                }}
                isOpen={requiresConfirmation !== null}
            />

            <ScheduledMessageDialog
                modalRef={dialogRef}
                isOpen={dialogOpen}
                onCreate={onCreate}
                onClose={() => {
                    setDialogOpen.off();
                }}
            />
        </Box>
    );
};