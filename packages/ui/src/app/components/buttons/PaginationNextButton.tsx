import React from 'react';
import { PaginationNext } from '@ajna/pagination';

export const PaginationNextButton = (): JSX.Element => {
    return <PaginationNext minWidth={'50px'} colorScheme='gray' color='black'>Next</PaginationNext>;
};
