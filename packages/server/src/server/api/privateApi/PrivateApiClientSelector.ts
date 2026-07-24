export type PrivateApiSocketState = {
    destroyed?: boolean;
};

export const selectPrivateApiClients = <SocketType extends PrivateApiSocketState>(
    connectedClients: SocketType[],
    clientsByProcessIdentifier: Record<string, SocketType>,
    targetProcessIdentifier?: string
): SocketType[] => {
    if (targetProcessIdentifier) {
        const targetClient = clientsByProcessIdentifier[targetProcessIdentifier];
        return targetClient != null && !targetClient.destroyed ? [targetClient] : [];
    }

    return connectedClients.filter(client => !client.destroyed);
};
