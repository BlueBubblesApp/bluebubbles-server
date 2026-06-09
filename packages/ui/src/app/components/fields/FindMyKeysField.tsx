import React, { useState, useEffect, useCallback } from 'react';
import {
    FormControl,
    FormHelperText,
    Text,
    Box,
    Stack,
    Button,
    Badge,
    HStack,
    Link
} from '@chakra-ui/react';
import {
    getEnv,
    getFindMyKeysStatus,
    importFindMyKeys,
    FindMyKeysStatus
} from '../../utils/IpcUtils';
import { showSuccessToast, showErrorToast } from '../../utils/ToastUtils';

type KeyType = 'LocalStorage' | 'FMIP' | 'FMF';

const KEY_LABELS: Record<KeyType, string> = {
    LocalStorage: 'Friend Locations (LocalStorage.key)',
    FMIP: 'Devices & Items (FMIPDataManager.bplist)',
    FMF: 'Friend Names (FMFDataManager.bplist)'
};

const KeyBadge = ({ label, status }: { label: string; status?: { present: boolean; valid: boolean } }): JSX.Element => {
    let color = 'red';
    let text = 'Missing';
    if (status?.present && status?.valid) {
        color = 'green';
        text = 'Imported';
    } else if (status?.present && !status?.valid) {
        color = 'orange';
        text = 'Invalid';
    }

    return (
        <HStack justifyContent='space-between' width='100%'>
            <Text fontSize='sm'>{label}</Text>
            <Badge colorScheme={color}>{text}</Badge>
        </HStack>
    );
};

export const FindMyKeysField = (): JSX.Element => {
    const [env, setEnv] = useState({} as Record<string, any>);
    const [status, setStatus] = useState(null as FindMyKeysStatus | null);
    const [importing, setImporting] = useState(false);

    const refreshStatus = useCallback(async () => {
        try {
            setStatus(await getFindMyKeysStatus());
        } catch {
            setStatus(null);
        }
    }, []);

    useEffect(() => {
        getEnv().then(setEnv);
        refreshStatus();
    }, [refreshStatus]);

    // Decryption-based Find My is only required/used on macOS 14.4 and later (where Apple
    // started encrypting the Find My location cache).
    if (!env.isMinSonoma14_4) return <></>;

    const onImport = async () => {
        setImporting(true);
        try {
            const { canceled, result } = await importFindMyKeys();
            if (canceled || !result) return;

            const imported = Object.entries(result)
                .filter(([, v]) => v === 'imported')
                .map(([k]) => k);
            const failed = Object.entries(result).filter(([, v]) => v !== 'imported');

            if (imported.length > 0) {
                showSuccessToast({ description: `Imported ${imported.length} Find My key(s): ${imported.join(', ')}` });
            }
            if (failed.length > 0) {
                showErrorToast({
                    description: `Could not import: ${failed.map(([k, v]) => `${k} (${v})`).join(', ')}`
                });
            }

            await refreshStatus();
        } catch (ex: any) {
            showErrorToast({ description: `Failed to import Find My keys: ${String(ex?.message ?? ex)}` });
        } finally {
            setImporting(false);
        }
    };

    return (
        <Box mt={3}>
            <Text fontSize='md' fontWeight='bold'>Find My Decryption Keys</Text>
            <FormControl mt={2}>
                <Stack direction='column' maxWidth='32em' spacing={1}>
                    <KeyBadge label={KEY_LABELS.LocalStorage} status={status?.LocalStorage} />
                    <KeyBadge label={KEY_LABELS.FMIP} status={status?.FMIP} />
                    <KeyBadge label={KEY_LABELS.FMF} status={status?.FMF} />
                </Stack>
                <Button size='xs' mt={3} onClick={onImport} isLoading={importing}>
                    Import Keys from Folder
                </Button>
                <FormHelperText>
                    <Text>
                        On macOS 14.4+, Apple encrypts the Find My location cache. BlueBubbles needs the
                        three decryption keys to read device and friend locations without code injection.
                        Extract them with{' '}
                        <Link
                            color='blue.500'
                            target='_blank'
                            href='https://github.com/manonstreet/findmy-key-extractor'
                        >
                            findmy-key-extractor
                        </Link>
                        , then click the button above and select the generated <b>keys</b> folder. The keys are
                        stable across reboots, so you only need to import them once.
                    </Text>
                </FormHelperText>
            </FormControl>
        </Box>
    );
};
