import test from "node:test";
import assert from "node:assert/strict";

import {
    buildChatSnapshotQuery,
    buildChatTransitionQuery,
    compareDecimalStrings,
    parseChatSnapshotRows,
    parseChatTransitionRows,
    supportsChatStateSnapshot
} from "../src/server/databases/imessage/snapshot/ChatStateSnapshot";

/** Snapshot queries require chat.last_read_message_timestamp (High Sierra+). */
test("supports chat-state snapshots only on High Sierra or later", () => {
    assert.equal(supportsChatStateSnapshot(false), false);
    assert.equal(supportsChatStateSnapshot(true), true);
});

/** The live poll may inspect only Apple's indexed unread-message candidates. */
test("transition query derives read state from unread-only message candidates", () => {
    const sql = buildChatTransitionQuery().replace(/\s+/g, " ");

    assert.match(sql, /WITH unread_chat_ids AS/i);
    assert.match(sql, /FROM message m/i);
    assert.match(sql, /m\.is_read = 0/i);
    assert.match(sql, /m\.is_from_me = 0/i);
    // Ventura preserves date_read when a user manually marks a previously read chat unread.
    assert.doesNotMatch(sql, /m\.date_read = 0/i);
    assert.match(sql, /m\.item_type = 0/i);
    // Ordinary messages always count. Associated events count only when they are
    // the newest row in the chat, so stale historical Tapbacks stay ignored.
    assert.match(sql, /COALESCE\(m\.associated_message_type, 0\) = 0/i);
    assert.match(sql, /COALESCE\(m\.associated_message_type, 0\) != 0/i);
    assert.match(sql, /NOT EXISTS/i);
    assert.match(sql, /newer_m\.date > m\.date/i);
    assert.match(sql, /newer_m\.date = m\.date\s+AND\s+newer_m\.ROWID > m\.ROWID/i);
    assert.match(sql, /newer_j\.chat_id = j\.chat_id/i);
    assert.match(sql, /CAST\s*\(\s*c\.ROWID\s+AS TEXT\s*\)\s+AS row_id/i);
    assert.doesNotMatch(sql, /COUNT\s*\(/i);
    assert.doesNotMatch(sql, /GROUP BY/i);
});

test("transition rows merge duplicate GUIDs with unread winning", () => {
    const entries = parseChatTransitionRows([
        { guid: "duplicate", is_read: 1, has_messages: 0, read_pointer: "100", row_id: "2" },
        {
            guid: "duplicate",
            is_read: 0,
            has_messages: 1,
            read_pointer: "900719925474099301",
            row_id: "1"
        }
    ]);
    assert.deepEqual(entries, [
        {
            guid: "duplicate",
            read: false,
            messageCount: 1,
            readPointer: "900719925474099301",
            sourceRowIds: ["1", "2"]
        }
    ]);
});

/** Chats with no incoming messages must still appear, as read. */
test("snapshot query left-joins so chats with no incoming messages still appear", () => {
    const sql = buildChatSnapshotQuery();
    assert.match(sql, /LEFT JOIN/i);
    assert.doesNotMatch(sql, /\bJOIN chat_message_join j ON j\.chat_id = c\.ROWID\s+JOIN\b/i);
});

/**
 * Read semantics must match the live poller exactly, or the snapshot and the
 * live read events will disagree and fight each other.
 */
test("snapshot counts only a newest associated event as unread", () => {
    const sql = buildChatSnapshotQuery().replace(/\s+/g, " ");
    assert.match(sql, /m\.item_type = 0/i);
    assert.match(sql, /m\.is_from_me = 0/i);
    assert.match(sql, /COALESCE\(m\.associated_message_type, 0\) = 0/i);
    assert.match(sql, /COALESCE\(m\.associated_message_type, 0\) != 0/i);
    assert.match(sql, /NOT EXISTS/i);
    assert.match(sql, /newer_m\.date > m\.date/i);
    assert.match(sql, /newer_m\.date = m\.date\s+AND\s+newer_m\.ROWID > m\.ROWID/i);
    assert.match(sql, /newer_j\.chat_id = j\.chat_id/i);
    // A manually restored unread badge must count even when Apple retains the old read date.
    assert.doesNotMatch(sql, /date_read = 0/i);
});

test("a chat with no messages at all is read", () => {
    assert.deepEqual(parseChatSnapshotRows([{ guid: "iMessage;-;+155****1111", unread_count: null }]), [
        { guid: "iMessage;-;+155****1111", read: true }
    ]);
});

test("a chat with unread incoming messages is unread", () => {
    assert.deepEqual(parseChatSnapshotRows([{ guid: "iMessage;-;+155****1111", unread_count: 2 }]), [
        { guid: "iMessage;-;+155****1111", read: false }
    ]);
});

test("decimal string comparator is exact across length and lexical boundaries", () => {
    assert.equal(compareDecimalStrings("9", "100"), -1);
    assert.equal(compareDecimalStrings("100", "9"), 1);
    assert.equal(compareDecimalStrings("100", "100"), 0);
    assert.equal(compareDecimalStrings("900719925474099301", "900719925474099302"), -1);
});

test("rows without a guid are dropped rather than emitted as empty-guid chats", () => {
    const entries = parseChatSnapshotRows([
        { guid: null as unknown as string, unread_count: 0 },
        { guid: "iMessage;-;+155****1111", unread_count: 0 }
    ]);
    assert.deepEqual(entries, [{ guid: "iMessage;-;+155****1111", read: true }]);
});

test("duplicate guids collapse with unread winning", () => {
    const entries = parseChatSnapshotRows([
        { guid: "dup", unread_count: 0 },
        { guid: "dup", unread_count: 3 }
    ]);
    assert.deepEqual(entries, [{ guid: "dup", read: false }]);
});
