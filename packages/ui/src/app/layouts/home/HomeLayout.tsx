import React, { useEffect } from 'react';
import { ipcRenderer } from 'electron';
import {
    Spacer,
    Box,
    Badge,
    Divider,
    Flex,
    SimpleGrid,
    Stack,
    Text,
    IconButton,
    Popover,
    PopoverCloseButton,
    PopoverContent,
    PopoverHeader,
    PopoverBody,
    PopoverArrow,
    PopoverTrigger,
    UnorderedList,
    ListItem,
    SkeletonText,
    Tooltip
} from '@chakra-ui/react';
import QRCode from 'react-qr-code';
import { AiOutlineInfoCircle, AiOutlineQrcode } from 'react-icons/ai';

import './styles.css';
import { useAppDispatch, useAppSelector } from '../../hooks';
import { buildQrData, copyToClipboard } from '../../utils/GenericUtils';
import { BiCopy } from 'react-icons/bi';
import { setStat } from '../../slices/StatsSlice';
import { formatNumber } from '../../utils/NumberUtils';


export const HomeLayout = (): JSX.Element => {
    const dispatch = useAppDispatch();
    const address = useAppSelector(state => state.config.server_address);
    const fcmClient = useAppSelector(state => state.config.fcm_client);
    const password = useAppSelector(state => state.config.password);
    const port = useAppSelector(state => state.config.socket_port);
    const qrCode = fcmClient ? buildQrData(password, address, fcmClient) : null;

    // Stats state
    const totalMessages: number | null = useAppSelector(state => state.statistics.total_messages) ?? null;
    const topGroup: string | null = useAppSelector(state => state.statistics.top_group) ?? null;
    const bestFriend: string | null = useAppSelector(state => state.statistics.best_friend) ?? null;
    const dailyMessages: number | null = useAppSelector(state => state.statistics.daily_messages) ?? null;
    const totalPictures: number | null = useAppSelector(state => state.statistics.total_pictures) ?? null;
    const totalVideos: number | null = useAppSelector(state => state.statistics.total_videos) ?? null;

    const updateStats = () => {
        ipcRenderer.invoke('get-message-count').then((messageCount) => {
            dispatch(setStat({ name: 'total_messages', value: messageCount }));
        });
        

        ipcRenderer.invoke('get-individual-message-counts').then((dmCounts) => {
            let currentTopCount = 0;
            let currentTop = 'N/A';
            let isGroup = false;
            dmCounts.forEach((item: any) => {
                if (item.message_count > currentTopCount) {
                    const guid = item.chat_guid.replace('iMessage', '').replace(';+;', '').replace(';-;', '');
                    currentTopCount = item.message_count;
                    isGroup = (item.group_name ?? '').length > 0;
                    currentTop = isGroup ? item.group_name : guid;
                }
            });

            if (!isGroup) {
                ipcRenderer.invoke('get-contact-name', currentTop).then(e => {
                    if (!e && !e.firstName) {
                        dispatch(setStat({ name: 'best_friend', value: currentTop }));
                    } else {
                        dispatch(setStat({ name: 'best_friend', value: `${e.firstName} ${e?.lastName ?? ''}`.trim() }));
                    }
                }).catch(() => {
                    dispatch(setStat({ name: 'best_friend', value: currentTop }));
                });
            } else if (currentTop.length === 0) {
                dispatch(setStat({ name: 'best_friend', value: 'Unnamed Group' }));
            }
        });
        
        ipcRenderer.invoke('get-group-message-counts').then((groupCounts) => {
            let currentTopCount = 0;
            let currentTop = 'N/A';
            groupCounts.forEach((item: any) => {
                if (item.message_count > currentTopCount) {
                    currentTopCount = item.message_count;
                    currentTop = item.group_name;
                }
            });
            dispatch(setStat({ name: 'top_group', value: currentTop }));
        });
        

        const after = new Date();
        after.setDate(after.getDate() - 1);
        ipcRenderer.invoke('get-message-count', { after }).then((dailyCount) => {
            dispatch(setStat({ name: 'daily_messages', value: dailyCount }));
        });
        

        ipcRenderer.invoke('get-chat-image-count').then((chatImageStats) => {
            let total = 0;
            chatImageStats.forEach((item: any) => {
                total += item.media_count ?? 0;
            });
            dispatch(setStat({ name: 'total_pictures', value: total }));
        });

        ipcRenderer.invoke('get-chat-video-count').then((chatVideoStats) => {
            let total = 0;
            chatVideoStats.forEach((item: any) => {
                total += item.media_count ?? 0;
            });
            dispatch(setStat({ name: 'total_videos', value: total }));
        });
    };

    // Run-once to fetch stats
    useEffect(() => {
        updateStats();
        setInterval(updateStats, 60000);  // Refresh the stats every 1 minute
    }, []);

    return (
        <Box p={3} borderRadius={10}>
            <Flex flexDirection="column">
                <Stack direction='column' p={5}>
                    <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                        <Text fontSize='2xl'>Connection Details</Text>
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
                                        This page will detail your current connection details. This includes your&nbsp;
                                        server address and your local port.
                                    </Text>
                                    <br />
                                    <UnorderedList>
                                        <ListItem><strong>Server Address:</strong> This is the address that your clients will connect to</ListItem>
                                        <ListItem><strong>Local Port:</strong> This is the port that the HTTP server is running on, 
                                            and the port you will use when port forwarding&nbsp;
                                            for a dynamic DNS
                                        </ListItem>
                                    </UnorderedList>
                                </PopoverBody>
                            </PopoverContent>
                        </Popover>
                    </Flex>
                    <Divider orientation='horizontal' />
                    <Spacer />
                    <Flex flexDirection="row" justifyContent="space-between">
                        <Stack>
                            <Flex flexDirection="row" alignItems='center'>
                                <Text fontSize='md' fontWeight='bold' mr={2}>Server Address: </Text>
                                {(!address) ? (
                                    <SkeletonText noOfLines={1} />
                                ) : (
                                    <Text fontSize='md'>{address}</Text>
                                )}
                                <Tooltip label='Copy Address'>
                                    <IconButton
                                        ml={3}
                                        size='md'
                                        aria-label='Copy Address'
                                        icon={<BiCopy size='22px' />}
                                        onClick={() => copyToClipboard(address)}
                                    />
                                </Tooltip>
                                <Popover placement='bottom' isLazy={true}>
                                    <PopoverTrigger>
                                        <Box ml={2} _hover={{ color: 'brand.primary', cursor: 'pointer' }} >
                                            <Tooltip label='Show QR Code'>
                                                <IconButton
                                                    ml={1}
                                                    size='md'
                                                    aria-label='Show QR Code'
                                                    icon={<AiOutlineQrcode size='24px' />}
                                                />
                                            </Tooltip>
                                        </Box>
                                    </PopoverTrigger>
                                    <PopoverContent>
                                        <PopoverArrow />
                                        <PopoverCloseButton />
                                        <PopoverHeader>QR Code</PopoverHeader>
                                        <PopoverBody>
                                            <Flex justifyContent='center' flexDirection='column' alignItems='center'>
                                                <Text>
                                                    Your QR Code contains your server configuration so that clients can connect.
                                                    Your QR Code should remain <strong>private</strong> as it contains sensitive information!
                                                </Text>
                                                <Box border="5px solid" borderColor='white' mt={4} height='266px' width='266px' borderRadius='lg' mb={3}>
                                                    {(qrCode) ? <QRCode value={qrCode as string} /> : null}
                                                </Box>
                                            </Flex>
                                        </PopoverBody>
                                    </PopoverContent>
                                </Popover>
                            </Flex>
                            <Flex flexDirection="row">
                                <Text fontSize='md' fontWeight='bold' mr={2}>Local Port: </Text>
                                {(!port) ? (
                                    <SkeletonText noOfLines={1} />
                                ) : (
                                    <Text fontSize='md'>{port}</Text>
                                )}
                            </Flex>
                        </Stack>
                        <Divider orientation="vertical" />
                    </Flex>
                </Stack>
                <Stack direction='column' p={5}>
                    <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                        <Text fontSize='2xl'>iMessage Highlights</Text>
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
                                        These are just some fun stats that I included to give you a quick "snapshot"
                                        of your iMessage history on the Mac Device. This does not include messages that
                                        are on Apple's servers, only what is local to this device.
                                    </Text>
                                </PopoverBody>
                            </PopoverContent>
                        </Popover>
                    </Flex>
                    <Divider orientation='horizontal' />
                    <Spacer />
                    <SimpleGrid columns={3} spacing={5}>
                        <Box maxW='sm' borderWidth='1px' borderRadius='lg' overflow='hidden' p={5} m={1}>
                            <Badge borderRadius='full' px='2' colorScheme='teal' mb={2}>
                                Total Messages
                            </Badge>
                            <Spacer />
                            <Box
                                color='gray.500'
                                fontWeight='semibold'
                                letterSpacing='wide'
                            >
                                {(totalMessages === null) ? (
                                    <SkeletonText height={20} mt={2} noOfLines={3} />
                                ) : (
                                    <Text fontSize='2vw'>{formatNumber(totalMessages)}</Text>
                                )}
                            </Box>
                        </Box>
                        <Box maxW='sm' borderWidth='1px' borderRadius='lg' overflow='hidden' p={5} m={1}>
                            <Badge borderRadius='full' px='2' colorScheme='pink' mb={2}>
                                Top Group
                            </Badge>
                            <Spacer />
                            <Box
                                color='gray.500'
                                fontWeight='semibold'
                                letterSpacing='wide'
                            >
                                {(topGroup === null) ? (
                                    <SkeletonText height={20} mt={2} noOfLines={3} />
                                ) : (
                                    <Text fontSize='2vw'>{topGroup}</Text>
                                )}
                            </Box>
                        </Box>
                        <Box maxW='sm' borderWidth='1px' borderRadius='lg' overflow='hidden' p={5} m={1}>
                            <Badge borderRadius='full' px='2' colorScheme='purple' mb={2}>
                                Best Friend
                            </Badge>
                            <Spacer />
                            <Box
                                color='gray.500'
                                fontWeight='semibold'
                                letterSpacing='wide'
                            >
                                {(bestFriend === null) ? (
                                    <SkeletonText height={20} mt={2} noOfLines={3} />
                                ) : (
                                    <Text fontSize='2vw'>{bestFriend}</Text>
                                )}
                            </Box>
                        </Box>
                        <Box maxW='sm' borderWidth='1px' borderRadius='lg' overflow='hidden' p={5} m={1}>
                            <Badge borderRadius='full' px='2' colorScheme='yellow' mb={2}>
                                Daily Messages
                            </Badge>
                            <Spacer />
                            <Box
                                color='gray.500'
                                fontWeight='semibold'
                                letterSpacing='wide'
                            >
                                {(dailyMessages === null) ? (
                                    <SkeletonText height={20} mt={2} noOfLines={3} />
                                ) : (
                                    <Text fontSize='2vw'>{formatNumber(dailyMessages)}</Text>
                                )}
                            </Box>
                        </Box>
                        <Box maxW='sm' borderWidth='1px' borderRadius='lg' overflow='hidden' p={5} m={1}>
                            <Badge borderRadius='full' px='2' colorScheme='orange' mb={2}>
                                Total Pictures
                            </Badge>
                            <Spacer />
                            <Box
                                color='gray.500'
                                fontWeight='semibold'
                                letterSpacing='wide'
                            >
                                {(totalPictures === null) ? (
                                    <SkeletonText height={20} mt={2} noOfLines={3} />
                                ) : (
                                    <Text fontSize='2vw'>{formatNumber(totalPictures)}</Text>
                                )}
                            </Box>
                        </Box>
                        <Box maxW='sm' borderWidth='1px' borderRadius='lg' overflow='hidden' p={5} m={1}>
                            <Badge borderRadius='full' px='2' colorScheme='green' mb={2}>
                                Total Videos
                            </Badge>
                            <Spacer />
                            <Box
                                color='gray.500'
                                fontWeight='semibold'
                                letterSpacing='wide'
                            >
                                {(totalVideos === null) ? (
                                    <SkeletonText height={20} mt={2} noOfLines={3} />
                                ) : (
                                    <Text fontSize='2vw'>{formatNumber(totalVideos)}</Text>
                                )}
                            </Box>
                        </Box>
                    </SimpleGrid>
                </Stack>
            </Flex>
        </Box>
    );
};