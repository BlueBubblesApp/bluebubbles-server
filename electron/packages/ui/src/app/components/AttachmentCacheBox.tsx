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
import { BiRefresh, BiTrash } from 'react-icons/bi';
import { clearAttachmentCache, getAttachmentCacheInfo } from '../utils/IpcUtils';
import { showErrorToast, showSuccessToast } from 'app/utils/ToastUtils';


const spin = keyframes`
  from { transform: rotate(0deg); }
  to { transform: rotate(360deg); }
`;


export const AttachmentCacheBox = (): JSX.Element => {
    const [showProgress, setShowProgress] = useBoolean();
    const [meta, setMeta] = useState((): Record<string, any> | null => {
        return null;
    });

    const refreshInfo = () => {
        setShowProgress.on();
        getAttachmentCacheInfo().then(info => {
            // I like longer spinning
            setTimeout(() => {
                setShowProgress.off();
            }, 1000);

            if (!info) return;
            setMeta(info);
        });
    };

    const clearCache = () => {
        clearAttachmentCache().then(() => {
            showSuccessToast({ description: 'Successfully cleared attachment caches!' });
        }).catch(() => {
            showErrorToast({ description: 'Failed to clear attachment caches!' });
        });

        refreshInfo();
    };

    useEffect(() => {
        refreshInfo();
    }, []);

    return (
        <Box border='1px solid' borderColor={useColorModeValue('gray.200', 'gray.700')} borderRadius='xl' p={3} width='300px'>
            <Stack direction='row' align='center'>
                <Text fontSize='lg' fontWeight='bold'>Attachment Cache Info</Text>
                <Box
                    _hover={{ cursor: 'pointer' }}
                    animation={showProgress ? `${spin} infinite 1s linear` : undefined}
                    onClick={refreshInfo}
                >
                    <BiRefresh />
                </Box>
                <Box
                    _hover={{ cursor: 'pointer' }}
                    onClick={clearCache}
                >
                    <BiTrash />
                </Box>
            </Stack>
            <UnorderedList mt={2} ml={8}>
                <ListItem>
                    <Stack direction='row' align='center'>
                        <Text fontSize='md'><strong>Attachment Count</strong>:&nbsp;
                            <Box as='span'>{meta?.count ?? 'N/A'}</Box>
                        </Text>
                    </Stack>
                </ListItem>
                <ListItem>
                    <Stack direction='row' align='center'>
                        <Text fontSize='md'><strong>Cache Size (MB)</strong>:&nbsp;
                            <Box as='span'>{(meta?.size == null || meta?.size === 0) ? 'N/A' : (meta?.size / 1024 / 1024).toFixed(2)}</Box>
                        </Text>
                    </Stack>
                </ListItem>
            </UnorderedList>
        </Box>
    );
};