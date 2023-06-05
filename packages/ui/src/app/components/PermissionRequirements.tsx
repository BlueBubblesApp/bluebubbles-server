import React from 'react';
import {
    useBoolean,
    Box,
    Text,
    Stack,
    ListItem,
    Popover,
    PopoverArrow,
    PopoverBody,
    PopoverCloseButton,
    PopoverContent,
    PopoverHeader,
    PopoverTrigger,
    UnorderedList,
    useColorModeValue,
    keyframes
} from '@chakra-ui/react';
import { BiRefresh } from 'react-icons/bi';
import { useAppSelector } from '../hooks';
import { AiOutlineInfoCircle } from 'react-icons/ai';
import { checkPermissions, openAccessibilityPrefs, openFullDiskPrefs } from '../utils/IpcUtils';
import { store } from '../store';
import { setConfig } from '../slices/ConfigSlice';
import { BsGear } from 'react-icons/bs';


type RequirementsItem = {
    name: string;
    pass: boolean;
    solution: string;
};

const spin = keyframes`
  from { transform: rotate(0deg); }
  to { transform: rotate(360deg); }
`;


export const PermissionRequirements = (): JSX.Element => {
    const permissions: Array<RequirementsItem> = (useAppSelector(state => state.config.permissions) ?? []);
    const [showProgress, setShowProgress] = useBoolean();
    const [showAccessibilityProgress, setShowAccessibilityProgress] = useBoolean();

    const refreshRequirements = () => {
        setShowProgress.on();
        checkPermissions().then(permissions => {
            // I like longer spinning
            setTimeout(() => {
                setShowProgress.off();
            }, 1000);

            if (!permissions) return;
            store.dispatch(setConfig({ name: 'permissions', value: permissions }));
        });
    };

    return (
        <Box border='1px solid' borderColor={useColorModeValue('gray.200', 'gray.700')} borderRadius='xl' p={3} width='350px'>
            <Stack direction='row' align='center'>
                <Text fontSize='lg' fontWeight='bold'>macOS Permissions</Text>
                <Box
                    _hover={{ cursor: 'pointer' }}
                    animation={showProgress ? `${spin} infinite 1s linear` : undefined}
                    onClick={refreshRequirements}
                >
                    <BiRefresh />
                </Box>
            </Stack>
            <UnorderedList mt={2} ml={8}>
                {permissions.map(e => (
                    <ListItem key={e.name}>
                        <Stack direction='row' align='center'>
                            <Text fontSize='md'><strong>{e.name}</strong>:&nbsp;
                                <Box as='span' color={e.pass ? 'green' : 'red'}>{e.pass ? 'Pass' : 'Fail'}</Box>
                            </Text>
                            {(!e.pass) ? (
                                <>
                                    <Popover trigger='hover'>
                                        <PopoverTrigger>
                                            <Box ml={2} _hover={{ color: 'brand.primary', cursor: 'pointer' }}>
                                                <AiOutlineInfoCircle />
                                            </Box>
                                        </PopoverTrigger>
                                        <PopoverContent>
                                            <PopoverArrow />
                                            <PopoverCloseButton />
                                            <PopoverHeader>How to Fix</PopoverHeader>
                                            <PopoverBody>
                                                <Text>
                                                    {e.solution}
                                                </Text>
                                            </PopoverBody>
                                        </PopoverContent>
                                    </Popover>
                                    <Box
                                        _hover={{ cursor: 'pointer' }}
                                        animation={showAccessibilityProgress ? `${spin} infinite 1s linear` : undefined}
                                        onClick={() => {
                                            setShowAccessibilityProgress.on();
                                            setTimeout(() => {
                                                setShowAccessibilityProgress.off();
                                            }, 1000);

                                            if (e.name === 'Accessibility') {
                                                openAccessibilityPrefs();
                                            } else if (e.name === 'Full Disk Access') {
                                                openFullDiskPrefs();
                                            }
                                        }}
                                    >
                                        <BsGear />
                                    </Box>
                                </>
                            ): null}
                        </Stack>
                    </ListItem>
                ))}
            </UnorderedList>
        </Box>
    );
};