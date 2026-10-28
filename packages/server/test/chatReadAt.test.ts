import { strict as assert } from "node:assert";
import test from "node:test";

import { readPointerToEpochMs } from "../src/server/databases/imessage/snapshot/ChatStateSnapshot";

// chat.last_read_message_timestamp is nanoseconds since 2001-01-01 UTC.
test("converts the chat read pointer to epoch milliseconds", () => {
    // Observed on Sequoia: the Schwab chat read at 2026-10-28 05:35:08.971 UTC.
    assert.equal(readPointerToEpochMs("814858508971925760"), Date.UTC(2026, 9, 28, 5, 35, 8, 971));
});

test("a chat never read has no read time", () => {
    assert.equal(readPointerToEpochMs("0"), undefined);
    assert.equal(readPointerToEpochMs(""), undefined);
});
