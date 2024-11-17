import React, { useState, useEffect } from 'react';
import {
    FormControl,
    FormHelperText,
    Checkbox,
    Text,
    Box,
    Stack,
    Button,
    Link
} from '@chakra-ui/react';
import { useAppSelector } from '../../hooks';
import { onCheckboxToggle } from '../../actions/ConfigActions';
import { PrivateApiRequirements } from '../PrivateApiRequirements';
import { getEnv } from '../../utils/IpcUtils';
import { PrivateApiStatus } from '../PrivateApiStatus';
import { FaceTimeCallingField } from './FaceTimeCallingField';

export interface PrivateApiFieldProps {
    helpTextMessages?: string;
    helpTextFaceTime?: string;
}

export const PrivateApiField = ({ helpTextMessages, helpTextFaceTime }: PrivateApiFieldProps): JSX.Element => {
    const privateApi: boolean = (useAppSelector(state => state.config.enable_private_api) ?? false);
    const ftPrivateApi: boolean = (useAppSelector(state => state.config.enable_ft_private_api) ?? false);
    const [env, setEnv] = useState({} as Record<string, any>);

    useEffect(() => {
        getEnv().then((env) => {
            setEnv(env);
        });
    }, []);

    return (
        <Box mt={1}>
            <Stack direction='row'>
                <PrivateApiRequirements />
                <PrivateApiStatus />
            </Stack>
            <FormControl mt={5}>
                <Stack direction='column'>
                    <Button size='xs' width="150px" mb={2}>
                        <Link target="_blank" href="https://docs.bluebubbles.app/private-api/">
                            Private API Setup Docs
                        </Link>
                    </Button>
                    <Checkbox
                        id='enable_private_api'
                        isChecked={privateApi}
                        onChange={onCheckboxToggle}
                    >
                        Messages Private API
                    </Checkbox>
                    <FormHelperText>
                        {helpTextMessages ?? (
                            <Text>
                                If you have set up the Private API features,
                                enable this option to allow the server to communicate with the iMessage Private APIs.
                                This will run an instance of the Messages app with our helper dylib injected into it.
                                Enabling this will allow you to send reactions, replies, editing, effects, use FindMy, etc.
                            </Text>
                        )}
                    </FormHelperText>
                    <Checkbox
                        id='enable_ft_private_api'
                        isChecked={ftPrivateApi}
                        onChange={onCheckboxToggle}
                    >
                        FaceTime Private API
                    </Checkbox>
                    <FormHelperText>
                        {helpTextFaceTime ?? (
                            <Text>
                                If you have set up the Private API features,
                                enable this option to allow the server to communicate with the FaceTime Private APIs.
                                This will run an instance of the FaceTime app with our helper dylib injected into it.
                                Enabling this will allow the server to detect incoming FaceTime calls.
                            </Text>
                        )}
                    </FormHelperText>
                    {(ftPrivateApi && !!env?.isMinMonterey) ? (
                        <FaceTimeCallingField />
                    ) : null}
                </Stack>
            </FormControl>
        </Box>
    );
};