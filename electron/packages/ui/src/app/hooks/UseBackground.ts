import { useColorMode } from '@chakra-ui/react';

import { useAppSelector } from '../hooks';

export const useBackground = () => {
    const { colorMode } = useColorMode();
    const useOled = useAppSelector(state => state.config.use_oled_dark_mode ?? false);
    if (colorMode === 'light') return 'white';
    return (useOled) ? 'black' : 'gray.800';
};
