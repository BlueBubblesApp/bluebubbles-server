import Numeral from 'numeral';

export const formatNumber = (value: number): string => {
    if (value > 1000) {
        return Numeral(value).format('0.0a');
    }

    return String(value);
};