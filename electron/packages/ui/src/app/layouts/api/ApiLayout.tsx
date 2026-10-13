import React, { useRef } from 'react';
import { Box, Divider, Flex, LinkBox, Spacer, Stack, Text, useBoolean } from '@chakra-ui/react';
import {
    Menu,
    MenuButton,
    MenuList,
    MenuItem,
    Button,
    Popover,
    PopoverCloseButton,
    PopoverContent,
    PopoverHeader,
    PopoverBody,
    PopoverArrow,
    PopoverTrigger,
    Heading,
    LinkOverlay
} from '@chakra-ui/react';
import { BsChevronDown } from 'react-icons/bs';
import { AiOutlineInfoCircle, AiOutlinePlus } from 'react-icons/ai';
import { WebhooksTable } from '../../components/tables/WebhooksTable';
import { AddWebhookDialog } from '../../components/modals/AddWebhookDialog';
import { useAppSelector } from '../../hooks';


export const ApiLayout = (): JSX.Element => {
    const dialogRef = useRef(null);
    const [dialogOpen, setDialogOpen] = useBoolean();
    const webhooks = useAppSelector(state => state.webhookStore.webhooks);

    return (
        <Box p={3} borderRadius={10}>
            <Flex flexDirection="column">
                <Stack direction='column' p={5}>
                    <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                        <Text fontSize='2xl'>API</Text>
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
                                        Learn how you can interact with the API to automate and orchestrate iMessage-related
                                        actions. Our REST API gives you access to the underlying iMessage API in a
                                        more succinct and easy to digest way. We also offer webhooks so you can receive
                                        callbacks from the server.
                                    </Text>
                                </PopoverBody>
                            </PopoverContent>
                        </Popover>
                    </Flex>
                    <Divider orientation='horizontal' />
                    <Text>
                        BlueBubbles offers a high-level REST API to interact with the server, as well as iMessage itself.
                        With the API, you'll be able to send messages, fetch messages, filter chats, and more! To see what
                        else you can do in the API, please see the documentation below:
                    </Text>
                    <Spacer />
                    <LinkBox as='article' maxW='sm' px='5' pb={5} pt={2} borderWidth='1px' rounded='xl'>
                        <Text color='gray'>
                            https://documenter.getpostman.com
                        </Text>
                        <Heading size='sm' mt={2}>
                            <LinkOverlay href='https://documenter.getpostman.com/view/765844/UV5RnfwM' target='_blank'>
                                Click to view API documentation
                            </LinkOverlay>
                        </Heading>
                    </LinkBox>
                    
                </Stack>
                <Stack direction='column' p={5}>
                    <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                        <Text fontSize='2xl'>Webhooks</Text>
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
                                        Any webhooks registered here will receive a POST request whenever an iMessage event
                                        occurs. The body of the POST request will be a JSON payload containing the type of
                                        event and the event data.
                                    </Text>
                                </PopoverBody>
                            </PopoverContent>
                        </Popover>
                    </Flex>
                    <Divider orientation='horizontal' />
                    <Spacer />
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
                                <MenuItem icon={<AiOutlinePlus />} onClick={setDialogOpen.on}>
                                    Add Webhook
                                </MenuItem>
                            </MenuList>
                        </Menu>
                    </Box>
                    <Spacer />
                    <WebhooksTable webhooks={webhooks} />
                </Stack>
            </Flex>

            <AddWebhookDialog
                modalRef={dialogRef}
                isOpen={dialogOpen}
                onClose={() => setDialogOpen.off()}
            />
        </Box>
    );
};