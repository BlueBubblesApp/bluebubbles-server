import { mode } from '@chakra-ui/theme-tools';
import { useAppSelector } from './app/hooks';


export const baseTheme = {
    config: {
        initialColorMode: 'system',
        useSystemColorMode: false
    },
    styles: {
        global: (props: any) => {
            const useOled = useAppSelector(state => state.config.use_oled_dark_mode ?? false);
            return {
                body: {
                    bg: mode('white', (useOled) ? 'black' : 'gray.800')(props)
                },
            };
        },
    },
    colors: {
        brand: {
            primary: '#4A96E6'
        }
    }
};
