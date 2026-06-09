import React, { useState, useEffect } from 'react';
import {
    AlertDialog,
    AlertDialogOverlay,
    AlertDialogBody,
    AlertDialogContent,
    AlertDialogFooter,
    AlertDialogHeader,
    Button,
    Radio,
    RadioGroup,
    Stack,
    HStack,
    IconButton,
    Text,
    Box
} from '@chakra-ui/react';
import { FocusableElement } from '@chakra-ui/utils';
import { BiCopy } from 'react-icons/bi';
import { copyToClipboard } from '../../utils/GenericUtils';

interface LanUrlDialogProps {
    onCancel?: () => void;
    onConfirm?: (address: string) => void;
    isOpen: boolean;
    modalRef: React.RefObject<FocusableElement>;
    onClose: () => void;
    /** All detected non-internal LAN IPv4 addresses. */
    ips: string[];
    port: number;
    /** Whether the server uses HTTPS (custom certificate). */
    useHttps?: boolean;
    /** Currently selected server address, used to preselect the matching option. */
    currentAddress?: string;
}

export const LanUrlDialog = ({
    onCancel,
    onConfirm,
    isOpen,
    modalRef,
    onClose,
    ips,
    port,
    useHttps = false,
    currentAddress = ''
}: LanUrlDialogProps): JSX.Element => {
    const scheme = useHttps ? 'https' : 'http';
    const urls = ips.map(ip => `${scheme}://${ip}:${port}`);

    const [selected, setSelected] = useState(currentAddress && urls.includes(currentAddress) ? currentAddress : urls[0] ?? '');

    // Keep the selection valid when the available URLs change (e.g. port/scheme updates)
    useEffect(() => {
        if (!urls.includes(selected)) {
            setSelected(currentAddress && urls.includes(currentAddress) ? currentAddress : urls[0] ?? '');
        }
    }, [isOpen, ips.join(','), port, useHttps]);

    return (
        <AlertDialog isOpen={isOpen} leastDestructiveRef={modalRef} onClose={() => onClose()}>
            <AlertDialogOverlay>
                <AlertDialogContent>
                    <AlertDialogHeader fontSize='lg' fontWeight='bold'>
                        Select a LAN Address
                    </AlertDialogHeader>

                    <AlertDialogBody>
                        <Text mb={3}>
                            Your Mac has multiple local network addresses (e.g. Wi-Fi, Ethernet, or virtual
                            adapters). Pick the one your client devices can reach on your network. You can copy
                            any address to test which one works.
                        </Text>
                        <RadioGroup value={selected} onChange={setSelected}>
                            <Stack direction='column' spacing={2}>
                                {urls.map(url => (
                                    <HStack key={url} justifyContent='space-between'>
                                        <Radio value={url}>{url}</Radio>
                                        <IconButton
                                            size='sm'
                                            aria-label={`Copy ${url}`}
                                            icon={<BiCopy />}
                                            onClick={() => copyToClipboard(url)}
                                        />
                                    </HStack>
                                ))}
                            </Stack>
                        </RadioGroup>
                        {urls.length === 0 ? (
                            <Box mt={2}>
                                <Text color='red.400'>No LAN addresses were detected.</Text>
                            </Box>
                        ) : null}
                    </AlertDialogBody>

                    <AlertDialogFooter>
                        <Button
                            ref={modalRef as React.LegacyRef<HTMLButtonElement> | undefined}
                            onClick={() => {
                                if (onCancel) onCancel();
                                onClose();
                            }}
                        >
                            Cancel
                        </Button>
                        <Button
                            ml={3}
                            bg='brand.primary'
                            isDisabled={!selected}
                            ref={modalRef as React.LegacyRef<HTMLButtonElement> | undefined}
                            onClick={() => {
                                if (!selected) return;
                                if (onConfirm) onConfirm(selected);
                                onClose();
                            }}
                        >
                            Save
                        </Button>
                    </AlertDialogFooter>
                </AlertDialogContent>
            </AlertDialogOverlay>
        </AlertDialog>
    );
};
