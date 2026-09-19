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
import { getPrivateApiRequirements } from '../utils/IpcUtils';
import { store } from '../store';
import { setConfig } from '../slices/ConfigSlice';


type RequirementsItem = {
    name: string;
    pass: boolean;
    solution: string;
};

const spin = keyframes`
  from { transform: rotate(0deg); }
  to { transform: rotate(360deg); }
`;


export const PrivateApiRequirements = (): JSX.Element => {
    const requirements: Array<RequirementsItem> = (useAppSelector(state => state.config.private_api_requirements) ?? []);
    const [showProgress, setShowProgress] = useBoolean();

    const refreshRequirements = () => {
        setShowProgress.on();
        getPrivateApiRequirements().then(requirements => {
            // I like longer spinning
            setTimeout(() => {
                setShowProgress.off();
            }, 1000);
            
            if (!requirements) return;
            store.dispatch(setConfig({ name: 'private_api_requirements', value: requirements }));
        });
    };

    return (
        <Box border='1px solid' borderColor={useColorModeValue('gray.200', 'gray.700')} borderRadius='xl' p={3} width='325px'>
            <Stack direction='row' align='center'>
                <Text fontSize='lg' fontWeight='bold'>Private API Requirements</Text>
                <Box
                    _hover={{ cursor: 'pointer' }}
                    animation={showProgress ? `${spin} infinite 1s linear` : undefined}
                    onClick={refreshRequirements}
                >
                    <BiRefresh />
                </Box>
            </Stack>
            <UnorderedList mt={2} ml={8}>
                {requirements.map(e => (
                    <ListItem key={e.name}>
                        <Stack direction='row' align='center'>
                            <Text fontSize='md'><strong>{e.name}</strong>:&nbsp;
                                <Box as='span' color={e.pass ? 'green' : 'red'}>{e.pass ? 'Pass' : 'Fail'}</Box>
                            </Text>
                            {(!e.pass) ? (
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
                            ): null}
                        </Stack>
                    </ListItem>
                ))}
            </UnorderedList>
        </Box>
    );
};