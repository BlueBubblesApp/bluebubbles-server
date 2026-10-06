let inFlight: Promise<void> | null = null;

export function startBackgroundFindMyRefresh<T>(
    refresh: () => Promise<void>,
    readLocations: () => T[],
    publishLocations: (locations: T[]) => Promise<void>,
    onError: (error: unknown) => void
): void {
    if (inFlight) return;

    inFlight = (async () => {
        try {
            await refresh();
            await publishLocations(readLocations());
        } catch (error) {
            onError(error);
        } finally {
            inFlight = null;
        }
    })();
}
