import React from 'react';
import { PaginationPrevious } from '@ajna/pagination';

export const PaginationPreviousButton = (): JSX.Element => {
    return <PaginationPrevious minWidth={'75px'} colorScheme='gray' color='black'>Previous</PaginationPrevious>;
};
