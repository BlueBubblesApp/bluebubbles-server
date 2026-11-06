import { createStandaloneToast, ToastId } from '@chakra-ui/react';
import { AnyAction } from '@reduxjs/toolkit';
import { getRandomInt } from './GenericUtils';

const standaloneToast = createStandaloneToast();

export type ToastStatus = 'info' | 'warning' | 'success' | 'error';

export type ConfirmationItems = {
    [key: string]: {
        message: string,
        shouldDispatch?: boolean,
        func: (args?: NodeJS.Dict<any>) => void | AnyAction | Promise<void>
    }
};

export type ToastParams = {
    id?: ToastId,
    title?: string,
    description: string,
    status?: ToastStatus,
    duration?: number,
    isClosable?: boolean
    onCloseComplete?: () => void
};

export const showSuccessToast = ({
    id,
    title = 'Success',
    description,
    status = 'success',
    duration,
    isClosable,
    onCloseComplete
}: ToastParams): void => {
    showToast({ id, title, description, status, duration, isClosable, onCloseComplete});
};

export const showInfoToast = ({
    id,
    title = 'Info',
    description,
    status = 'info',
    duration,
    isClosable,
    onCloseComplete
}: ToastParams): void => {
    showToast({ id, title, description, status, duration, isClosable, onCloseComplete});
};

export const showWarnToast = ({
    id,
    title = 'Warning',
    description,
    status = 'warning',
    duration,
    isClosable,
    onCloseComplete
}: ToastParams): void => {
    showToast({ id, title, description, status, duration, isClosable, onCloseComplete});
};

export const showErrorToast = ({
    id,
    title = 'Error',
    description,
    status = 'error',
    duration,
    isClosable,
    onCloseComplete
}: ToastParams): void => {
    showToast({ id, title, description, status, duration, isClosable, onCloseComplete});
};

export const showToast = ({
    id = 'global',
    title,
    description,
    status = 'info',
    duration = 3000,
    isClosable = true,
    onCloseComplete
}: ToastParams): void => {
    const finalId = `${id}-${String(getRandomInt(10000))}`;
    standaloneToast.toast({ id: finalId, title, description, status, duration, isClosable, onCloseComplete });
};