import React from 'react';
import { useColorMode, useColorModeValue } from '@chakra-ui/react';

export const withColorModeHooks = (Elem: any): (props: any) => JSX.Element => {
    // eslint-disable-next-line react/display-name
    return (props: any): JSX.Element => {
        return <Elem
            useColorModeValue={useColorModeValue}
            useColorMode={useColorMode()}
            {...props}
        />;
    };
};