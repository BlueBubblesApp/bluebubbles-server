import React, { useEffect, useState } from 'react';
import {
    useBoolean,
    Box,
    Text,
    Stack,
    ListItem,
    UnorderedList,
    useColorModeValue,
    keyframes
} from '@chakra-ui/react';
import { BiRefresh } from 'react-icons/bi';
import { getPrivateApiStatus } from '../utils/IpcUtils';

const spin = keyframes`
  from { transform: rotate(0deg); }
  to { transform: rotate(360deg); }
`;


export const PrivateApiStatus = (): JSX.Element => {
    const [showProgress, setShowProgress] = useBoolean();
    const [status, setStatus] = useState((): NodeJS.Dict<any> | null => {
        return null;
    });

    const refreshStatus = () => {
        setShowProgress.on();
        getPrivateApiStatus().then(status => {
            // I like longer spinning
            setTimeout(() => {
                setShowProgress.off();
            }, 1000);
            
            if (!status) return;
            setStatus(status);
        });
    };

    useEffect(() => {
        refreshStatus();
    }, []);

    const connected = status?.connected === null ? '...' : (status?.connected ?? false) ? 'Yes' : 'No';
    return (
        <Box border='1px solid' borderColor={useColorModeValue('gray.200', 'gray.700')} borderRadius='xl' p={3} width='325px'>
            <Stack direction='row' align='center'>
                <Text fontSize='lg' fontWeight='bold'>Private API Status</Text>
                <Box
                    _hover={{ cursor: 'pointer' }}
                    animation={showProgress ? `${spin} infinite 1s linear` : undefined}
                    onClick={refreshStatus}
                >
                    <BiRefresh />
                </Box>
            </Stack>
            <UnorderedList mt={2} ml={8}>
                <ListItem>
                    <Text fontSize='md'><strong>Connected</strong>:&nbsp;
                        <Box as='span'>{connected}</Box>
                    </Text>
                </ListItem>
                <ListItem>
                    <Text fontSize='md'><strong>Port</strong>:&nbsp;
                        <Box as='span'>{status?.port ?? '...'}</Box>
                    </Text>
                </ListItem>
            </UnorderedList>
        </Box>
    );
};