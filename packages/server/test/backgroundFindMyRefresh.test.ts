import assert from "node:assert/strict";
import test from "node:test";

import { startBackgroundFindMyRefresh } from "../src/server/api/lib/findmy/BackgroundFindMyRefresh";

test("returns immediately while Find My refresh continues and publishes afterward", async () => {
    let releaseRefresh!: () => void;
    const refreshBlocked = new Promise<void>(resolve => {
        releaseRefresh = resolve;
    });
    const calls: string[] = [];

    const result = startBackgroundFindMyRefresh(
        async () => {
            calls.push("refresh-started");
            await refreshBlocked;
            calls.push("refresh-finished");
        },
        () => {
            calls.push("read");
            return ["fresh-location"];
        },
        async locations => {
            calls.push(`publish:${locations.join(",")}`);
        },
        error => {
            throw error;
        }
    );

    assert.equal(result, undefined);
    assert.deepEqual(calls, ["refresh-started"]);

    releaseRefresh();
    await new Promise(resolve => setImmediate(resolve));

    assert.deepEqual(calls, ["refresh-started", "refresh-finished", "read", "publish:fresh-location"]);
});

test("coalesces overlapping Find My refresh requests", async () => {
    let releaseRefresh!: () => void;
    const refreshBlocked = new Promise<void>(resolve => {
        releaseRefresh = resolve;
    });
    let refreshCalls = 0;
    let publishCalls = 0;

    const start = () =>
        startBackgroundFindMyRefresh(
            async () => {
                refreshCalls += 1;
                await refreshBlocked;
            },
            () => ["fresh-location"],
            async () => {
                publishCalls += 1;
            },
            error => {
                throw error;
            }
        );

    start();
    start();
    assert.equal(refreshCalls, 1);

    releaseRefresh();
    await new Promise(resolve => setImmediate(resolve));

    assert.equal(refreshCalls, 1);
    assert.equal(publishCalls, 1);
});

test("contains background refresh failures without producing an unhandled rejection", async () => {
    const errors: unknown[] = [];

    startBackgroundFindMyRefresh(
        async () => {
            throw new Error("synthetic refresh failure");
        },
        () => ["must-not-read"],
        async () => {
            throw new Error("must not publish");
        },
        error => errors.push(error)
    );

    await new Promise(resolve => setImmediate(resolve));

    assert.equal(errors.length, 1);
    assert.match(String(errors[0]), /synthetic refresh failure/);
});
