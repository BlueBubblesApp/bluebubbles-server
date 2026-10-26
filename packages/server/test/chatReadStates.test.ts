import test from "node:test";
import assert from "node:assert/strict";

import { buildChatUnreadCountQuery, isChatFullyRead } from "../src/server/databases/imessage/pollers/IncomingReadEventDetector";

/**
 * The forward detector fires when one message's read pointer advances, which is
 * not the same as the chat being read. Emitting an unconditional `read: true`
 * cleared the badge while other messages were still unread.
 */
test("reports a chat as fully read when nothing is awaiting a read", async () => {
    const db = { query: async () => [{ chat_count: 1, unread_count: 0 }] } as any;
    assert.equal(await isChatFullyRead(db, "iMessage;-;+15551234567"), true);
});

test("reports a chat as not fully read while a message is awaiting a read", async () => {
    const db = { query: async () => [{ chat_count: 1, unread_count: 2 }] } as any;
    assert.equal(await isChatFullyRead(db, "iMessage;-;+15551234567"), false);
});

test("does not report a deleted or missing chat as fully read", async () => {
    assert.equal(
        await isChatFullyRead({ query: async () => [{ chat_count: 0, unread_count: null }] } as any, "chat"),
        false
    );
    assert.equal(await isChatFullyRead({ query: async () => [] } as any, "chat"), false);
});

test("scopes the unread count to the requested chat via a bound parameter", async () => {
    const calls: Array<[string, unknown[]]> = [];
    const db = {
        query: async (sql: string, params: unknown[]) => {
            calls.push([sql, params]);
            return [{ unread_count: 0 }];
        }
    } as any;

    await isChatFullyRead(db, "iMessage;-;+15551234567");
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0][1], ["iMessage;-;+15551234567"]);
    assert.match(calls[0][0].replace(/\s+/g, " "), /c\.guid = \?/);
});

test("the per-chat unread query counts only real incoming messages", () => {
    const sql = buildChatUnreadCountQuery().replace(/\s+/g, " ");
    for (const clause of ["m.is_from_me = 0", "m.item_type = 0", "COALESCE(m.associated_message_type, 0) = 0"]) {
        assert.ok(sql.includes(clause), `per-chat query must include ${clause}`);
    }
});
