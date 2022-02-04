import React from 'react';
import {
    IconButton,
    Box,
    Flex,
    HStack,
    useColorModeValue,
    Link,
    Text,
    Tooltip,
    Switch,
    FormControl,
    useColorMode,
    Spacer,
    Divider
} from '@chakra-ui/react';
import { FiGithub, FiMessageCircle } from 'react-icons/fi';
import { FaDiscord } from 'react-icons/fa';
import { AiOutlineHome } from 'react-icons/ai';
import { MdOutlineAttachMoney, MdOutlineLightMode, MdOutlineDarkMode } from 'react-icons/md';
import { WalkthroughLayout } from '../../layouts/walkthrough/WalkthroughLayout'; 
import logo from '../../../images/logo/icon-64.png';


export const Setup = (): JSX.Element => {
    return (
        <Box height="100%">
            <NavBar />
            <Box p="2">
                <WalkthroughLayout />
            </Box>
        </Box>
    );
};

const NavBar = (): JSX.Element => {
    const { colorMode, toggleColorMode } = useColorMode();

    return (
        <Flex
            height="20"
            alignItems="center"
            borderBottomWidth="1px"
            borderBottomColor={useColorModeValue('gray.200', 'gray.700')}
            justifyContent='space-between'
            p={4}
            pl={6}
        >
            <Flex alignItems="center" justifyContent='flex-start'>
                <img src={logo} className="logo" alt="logo" height={48} />
                <Text fontSize="1xl" ml={2}>BlueBubbles</Text>
            </Flex>
            <Flex justifyContent='flex-end'>
                <HStack spacing={{ base: '0', md: '1' }}>
                    <Tooltip label="Website Home" aria-label="website-tip">
                        <Link href="https://bluebubbles.app" style={{ textDecoration: 'none' }} target="_blank">
                            <IconButton size="lg" variant="ghost" aria-label="website" icon={<AiOutlineHome />} />
                        </Link>
                    </Tooltip>
                    <Tooltip label="BlueBubbles Web" aria-label="website-tip">
                        <Link href="https://bluebubbles.app/web" style={{ textDecoration: 'none' }} target="_blank">
                            <IconButton size="lg" variant="ghost" aria-label="bluebubbles web" icon={<FiMessageCircle />} />
                        </Link>
                    </Tooltip>
                    <Tooltip label="Support Us" aria-label="donate-tip">
                        <Link href="https://bluebubbles.app/donate" style={{ textDecoration: 'none' }} target="_blank">
                            <IconButton size="lg" variant="ghost" aria-label="donate" icon={<MdOutlineAttachMoney />} />
                        </Link>
                    </Tooltip>
                    <Tooltip label="Join our Discord" aria-label="discord-tip">
                        <Link href="https://discord.gg/yC4wr38" style={{ textDecoration: 'none' }} target="_blank">
                            <IconButton size="lg" variant="ghost" aria-label="discord" icon={<FaDiscord />} />
                        </Link>
                    </Tooltip>
                    <Tooltip label="Read our Source Code" aria-label="github-tip">
                        <Link href="https://github.com/BlueBubblesApp" style={{ textDecoration: 'none' }} target="_blank">
                            <IconButton size="lg" variant="ghost" aria-label="github" icon={<FiGithub />} />
                        </Link>
                    </Tooltip>
                    <Spacer />
                    <Divider orientation="vertical" width={1} height={15} borderColor='gray' />
                    <Spacer />
                    <Spacer />
                    <Spacer />
                    <FormControl display='flex' alignItems='center'>
                        <Box mr={2}><MdOutlineDarkMode size={20} /></Box>
                        <Switch id='theme-mode-toggle' onChange={toggleColorMode} isChecked={colorMode === 'light'} />
                        <Box ml={2}><MdOutlineLightMode size={20} /></Box>
                    </FormControl>
                </HStack>
            </Flex>
        </Flex>
    );
};
