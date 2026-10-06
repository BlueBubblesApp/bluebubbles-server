export function startBackgroundFindMyRefresh<T>(
    refresh: () => Promise<void>,
    readLocations: () => T[],
    publishLocations: (locations: T[]) => Promise<void>,
    onError: (error: unknown) => void
): void {
    void (async () => {
        try {
            await refresh();
            await publishLocations(readLocations());
        } catch (error) {
            onError(error);
        }
    })();
}
