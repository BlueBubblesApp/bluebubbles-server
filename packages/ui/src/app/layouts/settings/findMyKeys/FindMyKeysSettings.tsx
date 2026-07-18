import React, { useEffect, useState } from 'react';
import {
    Box,
    Divider,
    Link,
    Stack,
    Text,
    Button,
    Spinner,
    UnorderedList,
    ListItem,
    useColorModeValue
} from '@chakra-ui/react';
import {
    selectFindMyKeysFolder,
    importFindMyKeys,
    getFindMyKeysStatus,
    decryptFindMyLocalStorage,
    getFindMyKeyPrerequisites
} from 'app/utils/IpcUtils';
import { showErrorToast, showSuccessToast } from 'app/utils/ToastUtils';

type KeyStatus = Record<string, boolean>;
type Prerequisites = { hasLldb: boolean; hasPython3: boolean; hasPip3: boolean; isSipDisabled: boolean };

const PREREQUISITE_LABELS: Record<keyof Prerequisites, { name: string; fix: string; fixUrl?: string }> = {
    hasLldb: {
        name: 'Xcode Command Line Tools (lldb)',
        fix: 'Install with: xcode-select --install'
    },
    hasPython3: {
        name: 'Python 3',
        fix: 'Install with: brew install python3'
    },
    hasPip3: {
        name: 'pip',
        fix: 'Install with: python3 -m ensurepip --upgrade'
    },
    isSipDisabled: {
        name: 'System Integrity Protection (SIP) disabled',
        fix: 'See our documentation',
        fixUrl: 'https://docs.bluebubbles.app/private-api/installation'
    }
};

export const FindMyKeysSettings = (): JSX.Element => {
    const [status, setStatus] = useState<KeyStatus | null>(null);
    const [prerequisites, setPrerequisites] = useState<Prerequisites | null>(null);
    const [isImporting, setIsImporting] = useState(false);
    const [isDecrypting, setIsDecrypting] = useState(false);
    const warningBorderColor = useColorModeValue('orange.300', 'orange.500');
    const statusBorderColor = useColorModeValue('gray.200', 'gray.700');

    const refreshStatus = () => {
        getFindMyKeysStatus().then(setStatus).catch(() => setStatus(null));
    };

    const onImport = async () => {
        const folder = await selectFindMyKeysFolder();
        if (!folder) return;

        setIsImporting(true);
        try {
            const result = await importFindMyKeys(folder);
            if (result.missing?.length > 0) {
                showErrorToast({
                    description: `Missing key file(s) in the selected folder: ${result.missing.join(', ')}`
                });
            } else {
                showSuccessToast({ description: 'Successfully imported Find My keys!' });
            }
        } catch (ex: any) {
            showErrorToast({ description: ex?.message ?? 'Failed to import Find My keys!' });
        } finally {
            setIsImporting(false);
            refreshStatus();
        }
    };

    const onDecrypt = async () => {
        setIsDecrypting(true);
        try {
            const outputPath = await decryptFindMyLocalStorage();
            showSuccessToast({ description: `Decrypted LocalStorage.db to: ${outputPath}` });
        } catch (ex: any) {
            showErrorToast({ description: ex?.message ?? 'Failed to decrypt LocalStorage.db!' });
        } finally {
            setIsDecrypting(false);
        }
    };

    useEffect(() => {
        refreshStatus();
        getFindMyKeyPrerequisites().then(setPrerequisites).catch(() => setPrerequisites(null));
    }, []);

    const hasAllKeys = status != null && Object.values(status).every(Boolean);
    const missingPrerequisites = prerequisites == null
        ? []
        : (Object.keys(PREREQUISITE_LABELS) as (keyof Prerequisites)[]).filter(key => !prerequisites[key]);

    return (
        <Stack direction='column' p={5}>
            <Text fontSize='2xl'>Find My Key Import</Text>
            <Divider orientation='horizontal' />

            {prerequisites == null ? (
                <Stack direction='row' align='center' pt={2}>
                    <Spinner size='sm' />
                    <Text fontSize='md'>Checking for required tools...</Text>
                </Stack>
            ) : missingPrerequisites.length > 0 ? (
                <Box
                    border='1px solid'
                    borderColor={warningBorderColor}
                    borderRadius='xl'
                    p={3}
                    width='fit-content'
                    minWidth='320px'
                >
                    <Text fontSize='md'>
                        Find My key import requires a few tools that were not found on this Mac:
                    </Text>
                    <UnorderedList mt={2} ml={8}>
                        {missingPrerequisites.map(key => (
                            <ListItem key={key}>
                                <Text fontSize='md'>
                                    <strong>{PREREQUISITE_LABELS[key].name}</strong> &mdash;{' '}
                                    {PREREQUISITE_LABELS[key].fixUrl ? (
                                        <Link href={PREREQUISITE_LABELS[key].fixUrl} target='_blank' color='teal.500'>
                                            {PREREQUISITE_LABELS[key].fix}
                                        </Link>
                                    ) : (
                                        PREREQUISITE_LABELS[key].fix
                                    )}
                                </Text>
                            </ListItem>
                        ))}
                    </UnorderedList>
                    <Text fontSize='sm' pt={2}>
                        Install the missing tool(s) above, then reopen this settings page.
                    </Text>
                </Box>
            ) : (
                <>
                    <Text fontSize='md'>
                        Import the Apple Find My encryption keys (<strong>LocalStorage.key</strong>,{' '}
                        <strong>FMIPDataManager.bplist</strong>, and <strong>FMFDataManager.bplist</strong>) so
                        BlueBubbles can use them to decrypt Find My data. These keys must first be extracted
                        using{' '}
                        <Link href='https://github.com/manonstreet/findmy-key-extractor' target='_blank' color='teal.500'>
                            findmy-key-extractor
                        </Link>{' '}
                        by manonstreet, following the steps in that project's README. Once you have a{' '}
                        <code>keys/</code> folder with the 3 files, select it below.
                    </Text>

                    <Box
                        border='1px solid'
                        borderColor={statusBorderColor}
                        borderRadius='xl'
                        p={3}
                        width='fit-content'
                        minWidth='320px'
                    >
                        <Text fontSize='lg' fontWeight='bold'>Key Status</Text>
                        <UnorderedList mt={2} ml={8}>
                            {status == null ? (
                                <ListItem>Loading...</ListItem>
                            ) : (
                                Object.entries(status).map(([fileName, imported]) => (
                                    <ListItem key={fileName}>
                                        <Text fontSize='md'>
                                            {fileName}: {imported ? '✅ Imported' : '❌ Not imported'}
                                        </Text>
                                    </ListItem>
                                ))
                            )}
                        </UnorderedList>
                    </Box>

                    <Stack direction='row' spacing={3} pt={2}>
                        <Button
                            onClick={onImport}
                            isLoading={isImporting}
                            leftIcon={isImporting ? <Spinner size='sm' /> : undefined}
                        >
                            Select Key Folder & Import
                        </Button>
                        <Button
                            onClick={onDecrypt}
                            isDisabled={!hasAllKeys}
                            isLoading={isDecrypting}
                            colorScheme='teal'
                        >
                            Decrypt LocalStorage.db
                        </Button>
                    </Stack>
                </>
            )}
        </Stack>
    );
};
