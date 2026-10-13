import React, { useState, useEffect } from 'react';
import {
    FormControl,
    FormLabel,
    FormHelperText,
    FormErrorMessage,
    Flex
} from '@chakra-ui/react';
import FilePicker from '../FilePicker';
import { useAppDispatch, useAppSelector } from '../../hooks';
import { showSuccessToast } from '../../utils/ToastUtils';
import { setConfig } from '../../slices/ConfigSlice';


export interface LandingPageFieldProps {
    helpText?: string;
}

export const LandingPageField = (): JSX.Element => {
    const dispatch = useAppDispatch();

    const savedPath: string = useAppSelector(state => state.config.landing_page_path) ?? '';
    const [landingPath, setLandingPath] = useState(savedPath);
    const [landingPathError, setLandingPathError] = useState('');
    const hasError: boolean = (landingPathError ?? '').length > 0;

    useEffect(() => {
        setLandingPath(savedPath);
    }, [savedPath]);

    /**
     * A handler & validator for saving a new landing page path.
     *
     * @param path - The new path to save
     */
    const saveLandingPage = (path: string): void => {
        dispatch(setConfig({ name: 'landing_page_path', value: path }));
        if (hasError) setLandingPathError('');
        showSuccessToast({
            id: 'settings',
            duration: 4000,
            description: 'Successfully saved landing page!'
        });
    };

    return (
        <FormControl isInvalid={hasError}>
            <FormLabel htmlFor='socket_port'>Custom Landing Page</FormLabel>
            <Flex flexDirection='row' justifyContent='flex-start' alignItems='center'>
                <FilePicker
                    accept='text/html'
                    placeholder={(landingPath.length === 0) ? 'Click to select an HTML file' : 'Click to select an HTML new file'}
                    multipleFiles={false}
                    clearButtonLabel='Unset'
                    inputProps={{ maxW: '300px' }}
                    hideClearButton={landingPath.length === 0}
                    onClear={() => {
                        if (hasError) setLandingPathError('');
                        dispatch(setConfig({ name: 'landing_page_path', value: '' }));
                        showSuccessToast({
                            id: 'settings',
                            duration: 4000,
                            description: 'Successfully unset landing page!'
                        });
                    }}
                    onFileChange={async (fileList: Array<File>) => {
                        if (hasError) setLandingPathError('');
                        if (fileList.length === 0) {
                            return setLandingPath('');
                        }

                        saveLandingPage(fileList[0].path);
                    }}
                />
            </Flex>
            {!hasError ? (
                <FormHelperText>
                    Selected: { landingPath.length === 0 ? 'No custom landing page set' : landingPath }
                </FormHelperText>
            ) : (
                <FormErrorMessage>{landingPathError}</FormErrorMessage>
            )}
        </FormControl>
    );
};