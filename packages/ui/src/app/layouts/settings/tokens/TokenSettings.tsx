import React, { useRef } from 'react';
import {
    Box, 
    Button, 
    Divider, 
    Menu,
    MenuButton, 
    Stack,     
    Table,
    Thead,
    Tbody,
    Tr,
    Th,
    Td,
    Flex,
    Text,
    useBoolean,
    Tooltip,
    Icon,
    GridItem
} from '@chakra-ui/react';
import { useAppDispatch, useAppSelector } from 'app/hooks';
import { TokenItem, remove } from 'app/slices/TokenSlice';
import { BsPlus } from 'react-icons/bs';
import { AddTokenDialog } from 'app/components/modals/AddTokenDialog';
import { FiTrash } from 'react-icons/fi';

export const TokensTable = ({ tokens }: { tokens: Array<TokenItem> }): JSX.Element => {
    const dispatch = useAppDispatch();
    return(
        <Table variant="striped" colorScheme="blue" size='sm'>
            <Thead>
                <Tr>
                    <Th>Name</Th>
                    <Th>Expire At</Th>
                </Tr>
            </Thead>
            <Tbody>
                {tokens.map(item => (
                    <Tr key={item.name}>
                        <Td wordBreak='break-all'>{item.name}</Td>
                        <Td wordBreak='break-all'>{item.expireAt}</Td>
                        <Tooltip label='Delete' placement='bottom'>
                            <GridItem _hover={{ cursor: 'pointer' }} onClick={() => dispatch(remove(item.name))}>
                                <Icon as={FiTrash} />
                            </GridItem>
                        </Tooltip>
                    </Tr>
                ))}
            </Tbody>
        </Table>
    );
};

export const TokenSettings = (): JSX.Element => {
    const dialogRef = useRef(null);
    const tokens = useAppSelector(state => state.tokenStore.tokens);
    const [dialogOpen, setDialogOpen] = useBoolean();

    return(
        <Box p={3} borderRadius={10}>
            <Stack direction='column' p={5}>
                <Text>Tokens</Text>
                <Divider orientation='horizontal' />
                <Box>
                    <Menu>
                        <MenuButton
                            as={Button}
                            rightIcon={<BsPlus />}
                            width="12em" 
                            mr={5}
                            onClick={setDialogOpen.on}>
                                Add a token
                        </MenuButton>
                    </Menu>
                </Box>
            </Stack>
            <Stack direction='column' p={5}>
                {(tokens.length === 0) ? (
                    <Flex justifyContent="center" alignItems="center">
                        <section style={{marginTop: 20}}>
                            <Text>You have no tokens registered with the server!</Text>
                        </section>
                    </Flex>                
                ) : null}
                {(tokens.length > 0) ? (
                    <TokensTable tokens={tokens} />
                ) : null}
            </Stack>
            <AddTokenDialog
                modalRef={dialogRef}
                isOpen={dialogOpen}
                onClose={() => setDialogOpen.off()}
            />
        </Box>
    );
};