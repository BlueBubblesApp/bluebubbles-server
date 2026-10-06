import { spawn } from "child_process";
import { FindMyLocationItem } from "./types";
import { coordinateLabel } from "./SecureLocationReader";

export type AddressLabels = {
    /** City-level caption, e.g. "Plano, TX". */
    short: string;
    /** Street or venue when Apple has one, otherwise the short label. */
    long: string;
};

/** Reverse geocodes coordinates in one call; index i of the result belongs to coordinates[i]. */
export type GeocodeBatch = (coordinates: Array<[number, number]>) => Promise<Array<AddressLabels | undefined>>;

const MAX_BATCH = 50;
const MAX_CACHED_CELLS = 1000;
const PER_COORDINATE_TIMEOUT_MS = 6000;

// SecureLocationReader shows the coordinates when Apple stored no label for the record.
// Real labels such as "Home" or "Work" are Apple's and are never replaced.
const needsAddress = (item: FindMyLocationItem): boolean => {
    const [latitude, longitude] = item.coordinates ?? [];
    return (
        Number.isFinite(latitude) &&
        Number.isFinite(longitude) &&
        Math.abs(latitude) <= 90 &&
        Math.abs(longitude) <= 180 &&
        (latitude !== 0 || longitude !== 0) &&
        item.short_address === coordinateLabel(item.coordinates)
    );
};

// Roughly 100 m cells, so GPS jitter reuses an earlier lookup. Held in memory only.
const cellOf = ([latitude, longitude]: [number, number]): string => `${latitude.toFixed(3)},${longitude.toFixed(3)}`;

export class FindMyAddressLabeler {
    private readonly cache = new Map<string, AddressLabels>();
    private queue: Promise<unknown> = Promise.resolve();

    constructor(private readonly geocode: GeocodeBatch) {}

    /** Fills in addresses that are already known, without waiting on the geocoder. */
    applyCached(locations: FindMyLocationItem[]): FindMyLocationItem[] {
        return locations.map(item => {
            const labels = needsAddress(item) ? this.cache.get(cellOf(item.coordinates)) : undefined;
            return labels ? { ...item, short_address: labels.short, long_address: labels.long } : item;
        });
    }

    /**
     * Geocodes every unknown cell in a single batch, then fills in addresses. Batches run
     * one at a time so overlapping refreshes reuse each other's results. Never rejects:
     * a failed lookup leaves the item as it was, to be retried on a later refresh.
     */
    label(locations: FindMyLocationItem[]): Promise<FindMyLocationItem[]> {
        const run = this.queue.then(async () => {
            const pending = new Map<string, [number, number]>();
            for (const item of locations) {
                const cell = cellOf(item.coordinates);
                if (needsAddress(item) && !this.cache.has(cell) && pending.size < MAX_BATCH) {
                    pending.set(cell, item.coordinates);
                }
            }

            if (pending.size > 0) {
                const cells = [...pending.keys()];
                const results = await this.geocode([...pending.values()]).catch(() => []);
                cells.forEach((cell, i) => {
                    if (results[i]) this.cache.set(cell, results[i]);
                });
                while (this.cache.size > MAX_CACHED_CELLS) this.cache.delete(this.cache.keys().next().value);
            }

            return this.applyCached(locations);
        });

        this.queue = run.catch(() => undefined);
        return run;
    }
}

/** Runs the packaged CLGeocoder helper once for the whole batch. */
export const createAppleGeocodeBatch =
    (binaryPath: string): GeocodeBatch =>
    coordinates =>
        new Promise(resolve => {
            const results: Array<AddressLabels | undefined> = [];
            const child = spawn(binaryPath, [], { stdio: ["pipe", "pipe", "ignore"] });
            // The helper bounds each lookup itself; this only stops a wedged process. Results
            // streamed before a kill are kept.
            const timeout = setTimeout(() => child.kill("SIGKILL"), PER_COORDINATE_TIMEOUT_MS * coordinates.length);
            const finish = () => {
                clearTimeout(timeout);
                resolve(results);
            };

            let buffered = "";
            child.stdout.setEncoding("utf8");
            child.stdout.on("data", chunk => {
                const lines = (buffered + chunk).split("\n");
                buffered = lines.pop() ?? "";
                for (const line of lines) {
                    try {
                        const { i, short, long } = JSON.parse(line);
                        if (Number.isInteger(i) && i >= 0 && i < coordinates.length && typeof short === "string") {
                            results[i] = { short, long: typeof long === "string" ? long : short };
                        }
                    } catch {
                        // Ignore a malformed line; the cell is retried on a later refresh.
                    }
                }
            });
            child.once("error", finish);
            child.once("close", finish);

            // Coordinates go over stdin, never argv, so they stay out of process listings.
            child.stdin.on("error", () => undefined);
            child.stdin.end(coordinates.map(([latitude, longitude]) => `${latitude} ${longitude}\n`).join(""));
        });
