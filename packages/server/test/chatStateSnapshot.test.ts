import test from "node:test";
import assert from "node:assert/strict";

import {
    buildChatSnapshotQuery,
    buildChatTransitionQuery,
    compareDecimalStrings,
    parseChatSnapshotRows,
    parseChatTransitionRows
} from "../src/server/databases/imessage/snapshot/ChatStateSnapshot";

/** The live poll must not scan the message table or aggregate all joins every 500ms. */
test("transition query short-circuits message existence without joining message rows", () => {
    const sql = buildChatTransitionQuery();
    assert.match(sql, /EXISTS\s*\(/i);
    assert.match(sql, /FROM chat_message_join j/i);
    assert.match(sql, /j\.chat_id\s*=\s*c\.ROWID/i);
    assert.match(sql, /CAST\s*\(\s*c\.ROWID\s+AS TEXT\s*\)\s+AS row_id/i);
    assert.doesNotMatch(sql, /JOIN\s+(?:chat_message_join|message)\b/i);
    assert.doesNotMatch(sql, /COUNT\s*\(/i);
    assert.doesNotMatch(sql, /unread_count/i);
});

test("transition rows merge duplicate GUIDs without losing a surviving message row", () => {
    const entries = parseChatTransitionRows([
        { guid: "duplicate", has_messages: 0, read_pointer: "100", row_id: "2" },
        { guid: "duplicate", has_messages: 1, read_pointer: "900719925474099301", row_id: "1" }
    ]);
    assert.deepEqual(entries, [
        {
            guid: "duplicate",
            messageCount: 1,
            readPointer: "900719925474099301",
            sourceRowIds: ["1", "2"]
        }
    ]);
});

/**
 * The snapshot drives DELETION on the client, so its chat set must be the
 * complete Apple chat list. `buildChatReadStatesQuery` inner-joins
 * chat_message_join and message, so a chat with no incoming messages never
 * appears in its results. Reusing it here would report real chats as absent
 * and the client would delete them.
 */
test("snapshot query left-joins so chats with no incoming messages still appear", () => {
    const sql = buildChatSnapshotQuery();
    assert.match(sql, /LEFT JOIN/i);
    assert.doesNotMatch(sql, /\bJOIN chat_message_join j ON j\.chat_id = c\.ROWID\s+JOIN\b/i);
});

/**
 * Read semantics must match the existing detector exactly, or the snapshot and
 * the live read events will disagree and fight each other.
 */
test("snapshot query excludes system events and tapbacks from the unread tally", () => {
    const sql = buildChatSnapshotQuery();
    assert.match(sql, /item_type = 0/i);
    assert.match(sql, /associated_message_type/i);
    assert.match(sql, /is_from_me = 0/i);
});

/** The pointer must stay TEXT; Apple timestamps exceed exact Number range. */
test("snapshot query casts the read pointer to text", () => {
    const sql = buildChatSnapshotQuery();
    assert.match(sql, /CAST\s*\(\s*MAX\s*\(\s*COALESCE\s*\(\s*c\.last_read_message_timestamp/i);
    assert.match(sql, /AS TEXT/i);
});

test("a chat with no messages at all is present, read, and carries pointer zero", () => {
    const entries = parseChatSnapshotRows([
        {
            guid: "iMessage;-;+155****1111",
            unread_count: null,
            is_archived: 0,
            message_count: 0,
            read_pointer: null
        }
    ]);
    assert.deepEqual(entries, [
        {
            guid: "iMessage;-;+155****1111",
            read: true,
            isArchived: false,
            messageCount: 0,
            readPointer: "0"
        }
    ]);
});

test("a chat with unread incoming messages is present and unread", () => {
    const entries = parseChatSnapshotRows([
        {
            guid: "iMessage;-;+155****1111",
            unread_count: 2,
            is_archived: 0,
            message_count: 2,
            read_pointer: "500"
        }
    ]);
    assert.deepEqual(entries, [
        {
            guid: "iMessage;-;+155****1111",
            read: false,
            isArchived: false,
            messageCount: 2,
            readPointer: "500"
        }
    ]);
});

test("snapshot carries archive state and counts every joined message", () => {
    const sql = buildChatSnapshotQuery();
    assert.match(sql, /is_archived/i);
    assert.match(sql, /message_count/i);
    assert.match(sql, /COUNT\s*\(\s*DISTINCT\s+m\.ROWID\s*\)/i);

    const entries = parseChatSnapshotRows([
        {
            guid: "iMessage;-;+155****1111",
            unread_count: 0,
            is_archived: 1,
            message_count: 7,
            read_pointer: "900719925474099301"
        }
    ]);
    assert.deepEqual(entries, [
        {
            guid: "iMessage;-;+155****1111",
            read: true,
            isArchived: true,
            messageCount: 7,
            readPointer: "900719925474099301"
        }
    ]);
});

/** Pointers beyond Number.MAX_SAFE_INTEGER must survive verbatim. */
test("read pointers larger than Number.MAX_SAFE_INTEGER remain exact strings", () => {
    const huge = "900719925474099301";
    const entries = parseChatSnapshotRows([
        { guid: "a", unread_count: 0, is_archived: 0, message_count: 1, read_pointer: huge }
    ]);
    assert.equal(entries[0].readPointer, huge);
    assert.notEqual(String(Number(huge)), huge);
});

test("decimal string comparator is exact across length and lexical boundaries", () => {
    assert.equal(compareDecimalStrings("9", "100"), -1);
    assert.equal(compareDecimalStrings("100", "9"), 1);
    assert.equal(compareDecimalStrings("100", "100"), 0);
    assert.equal(compareDecimalStrings("900719925474099301", "900719925474099302"), -1);
});

test("malformed read pointer rejects the snapshot row", () => {
    assert.throws(
        () =>
            parseChatSnapshotRows([
                { guid: "a", unread_count: 0, is_archived: 0, message_count: 1, read_pointer: "-5" }
            ]),
        /Invalid read pointer/
    );
});

test("rows without a guid are dropped rather than emitted as empty-guid chats", () => {
    const entries = parseChatSnapshotRows([
        {
            guid: null as unknown as string,
            unread_count: 0,
            is_archived: 0,
            message_count: 0,
            read_pointer: "0"
        },
        { guid: "iMessage;-;+155****1111", unread_count: 0, is_archived: 0, message_count: 1, read_pointer: "1" }
    ]);
    assert.deepEqual(entries, [
        {
            guid: "iMessage;-;+155****1111",
            read: true,
            isArchived: false,
            messageCount: 1,
            readPointer: "1"
        }
    ]);
});

test("duplicate guids collapse with unread, archive, count, and maximum pointer winning", () => {
    const entries = parseChatSnapshotRows([
        { guid: "dup", unread_count: 0, is_archived: 0, message_count: 2, read_pointer: "900" },
        { guid: "dup", unread_count: 3, is_archived: 1, message_count: 3, read_pointer: "100" }
    ]);
    assert.deepEqual(entries, [
        { guid: "dup", read: false, isArchived: true, messageCount: 3, readPointer: "900" }
    ]);
});
