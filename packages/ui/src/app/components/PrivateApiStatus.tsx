import React, { useEffect, useState } from 'react';
import {
    useBoolean,
    Box,
    Text,
    Stack,
    ListItem,
    UnorderedList,
    useColorModeValue,
    keyframes,
    Button
} from '@chakra-ui/react';
import { BiRefresh } from 'react-icons/bi';
import { getPrivateApiStatus, retryFindMyHelper } from '../utils/IpcUtils';

const spin = keyframes`
  from { transform: rotate(0deg); }
  to { transform: rotate(360deg); }
`;

export const PrivateApiStatus = (): JSX.Element => {
    const [showProgress, setShowProgress] = useBoolean();
    const [status, setStatus] = useState((): NodeJS.Dict<any> | null => {
        return null;
    });
    const [retrying, setRetrying] = useState(false);
    const [retryError, setRetryError] = useState<string | null>(null);

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
        let active = true;
        const update = () => {
            getPrivateApiStatus()
                .then(value => {
                    if (active && value) setStatus(value);
                })
                .catch(() => {});
        };
        update();
        const timer = setInterval(update, 2000);
        return () => {
            active = false;
            clearInterval(timer);
        };
    }, []);

    const retryFindMy = async () => {
        setRetrying(true);
        setRetryError(null);
        try {
            const findMy = await retryFindMyHelper();
            setStatus(previous => ({ ...previous, findMy }));
        } catch (error: any) {
            setRetryError(error?.message ?? 'Unable to start the Find My check.');
        } finally {
            setRetrying(false);
        }
    };

    const connected = status === null ? '...' : status?.messagesConnected ?? status?.connected ?? false ? 'Yes' : 'No';
    const findMy = status?.findMy as
        | { required?: boolean; requested?: boolean; status?: string; message?: string }
        | undefined;
    const findMyLabel =
        (
            { disabled: 'Disabled', initializing: 'Checking…', ready: 'Ready', unavailable: 'Unavailable' } as Record<
                string,
                string
            >
        )[findMy?.status ?? ''] ?? '...';
    return (
        <Box
            border="1px solid"
            borderColor={useColorModeValue('gray.200', 'gray.700')}
            borderRadius="xl"
            p={3}
            width="325px"
        >
            <Stack direction="row" align="center">
                <Text fontSize="lg" fontWeight="bold">
                    Private API Status
                </Text>
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
                    <Text fontSize="md">
                        <strong>Messages connected</strong>:&nbsp;
                        <Box as="span">{connected}</Box>
                    </Text>
                </ListItem>
                <ListItem>
                    <Text fontSize="md">
                        <strong>Port</strong>:&nbsp;
                        <Box as="span">{status?.port ?? '...'}</Box>
                    </Text>
                </ListItem>
            </UnorderedList>
            {findMy?.required ? (
                <Box mt={3}>
                    <Text>
                        <strong>Find My</strong>: {findMyLabel}
                    </Text>
                    {findMy.status !== 'ready' ? (
                        <Text mt={1} fontSize="sm">
                            {findMy.message}
                        </Text>
                    ) : null}
                    {findMy.requested && findMy.status !== 'ready' ? (
                        <Button
                            mt={2}
                            size="sm"
                            onClick={retryFindMy}
                            isLoading={retrying}
                            isDisabled={findMy.status === 'initializing'}
                        >
                            Retry Find My check
                        </Button>
                    ) : null}
                    {retryError ? (
                        <Text mt={1} fontSize="sm" color="red.500">
                            {retryError}
                        </Text>
                    ) : null}
                </Box>
            ) : null}
        </Box>
    );
};
