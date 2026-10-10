let inFlight: Promise<void> | null = null;

export function startBackgroundFindMyRefresh<T>(
    refresh: () => Promise<void>,
    readLocations: () => T[],
    publishLocations: (locations: T[]) => Promise<void>,
    onError: (error: unknown) => void,
    cleanup?: () => Promise<void>
): void {
    if (inFlight) return;

    inFlight = (async () => {
        try {
            await refresh();
            await publishLocations(readLocations());
        } catch (error) {
            onError(error);
        } finally {
            if (cleanup) {
                try {
                    await cleanup();
                } catch (error) {
                    onError(error);
                }
            }
            inFlight = null;
        }
    })();
}
