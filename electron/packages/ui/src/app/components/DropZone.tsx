import React from 'react';
import {
    Box,
    Flex,
    Text,
    Center
} from '@chakra-ui/react';
import { RiDragDropLine } from 'react-icons/ri';

interface DropZoneProps {
    text: string;
    isDragging?: boolean;
    isLoaded?: boolean;
    loadedText?: string | null;
}

const getColor = (isLoaded: boolean, isDragging: boolean) => (isDragging) ? 'brand.primary' : (isLoaded ? 'green' : 'gray.400');

export const DropZone = ({ text, isDragging = false, isLoaded = false, loadedText = null }: DropZoneProps): JSX.Element => {
    const dragColor = getColor(isLoaded, isDragging);
    const dragFontSize = isDragging ? 'lg' : 'md';
    const dragIconSize = isDragging ? 36 : 28;
    return (
        <Box
            borderRadius='3xl'
            borderWidth='1px'
            minHeight='100px'
            border='dashed'
            borderColor={dragColor}
            pl={5}
            pr={5}
        >
            <Center height='100%'>
                <Flex flexDirection="row" justifyContent="center" alignItems='center'>
                    <Box transition='all 2s ease'>
                        {/* The key is required for the color to change */}
                        <RiDragDropLine key={dragColor} size={dragIconSize} color={dragColor} />
                    </Box>
                    
                    <Text
                        ml={3}
                        color={dragColor}
                        transition='all .2s ease'
                        fontSize={dragFontSize}
                        textAlign='center'
                    >
                        {isLoaded && !isDragging ? loadedText : text}
                    </Text>
                </Flex>
            </Center>
        </Box>
    );
};