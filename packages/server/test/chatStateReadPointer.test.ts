import { strict as assert } from "node:assert";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";

import { buildChatSnapshotQuery, buildChatTransitionQuery } from "../src/server/databases/imessage/snapshot/ChatStateSnapshot";

/**
 * Observed on a Ventura server after the chat was read on an iPhone: the chat
 * pointer advanced past three incoming messages, but those rows kept
 * is_read = 0. iOS showed the chat as read; the server kept reporting it
 * unread for 14 hours. The pointer is what iOS renders its badge from, so a
 * row older than the pointer must not count as unread.
 */
function database() {
    const db = new DatabaseSync(":memory:");
    db.exec(`
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, is_archived INTEGER DEFAULT 0, last_read_message_timestamp INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, date INTEGER, is_read INTEGER, is_from_me INTEGER, item_type INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
    `);
    return db;
}

function addChat(db: DatabaseSync, guid: string, pointer: number | null) {
    const info = db.prepare("INSERT INTO chat (guid, last_read_message_timestamp) VALUES (?, ?)").run(guid, pointer);
    return Number(info.lastInsertRowid);
}

function addIncoming(db: DatabaseSync, chatId: number, date: number, isRead: number, assoc = 0) {
    const info = db
        .prepare("INSERT INTO message (date, is_read, is_from_me, item_type, associated_message_type) VALUES (?, ?, 0, 0, ?)")
        .run(date, isRead, assoc);
    db.prepare("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)").run(chatId, info.lastInsertRowid);
}

test("rows older than the chat's read pointer do not count as unread, in both queries", () => {
    const db = database();
    const chat = addChat(db, "iMessage;+;mukhi", 1_000);
    addIncoming(db, chat, 900, 1); // read normally
    addIncoming(db, chat, 950, 0); // is_read never flipped, but older than the pointer
    addIncoming(db, chat, 960, 0);
    addIncoming(db, chat, 970, 0, 2000); // newest row is a Tapback, also older than the pointer

    const snapshot = db.prepare(buildChatSnapshotQuery()).all() as Array<{ guid: string; unread_count: number }>;
    assert.equal(snapshot.length, 1);
    assert.equal(snapshot[0].unread_count, 0, "snapshot must report the chat read");

    const transition = db.prepare(buildChatTransitionQuery()).all() as Array<{ guid: string; is_read: number }>;
    assert.equal(transition.length, 1);
    assert.equal(transition[0].is_read, 1, "live poller must report the chat read");
});

test("a message newer than the pointer still counts as unread", () => {
    const db = database();
    const chat = addChat(db, "iMessage;+;mukhi", 1_000);
    addIncoming(db, chat, 950, 0);
    addIncoming(db, chat, 1_200, 0); // arrived after the last read

    const snapshot = db.prepare(buildChatSnapshotQuery()).all() as Array<{ unread_count: number }>;
    assert.equal(snapshot[0].unread_count, 1, "only the newer row counts");

    const transition = db.prepare(buildChatTransitionQuery()).all() as Array<{ is_read: number }>;
    assert.equal(transition[0].is_read, 0);
});

test("a chat with no read pointer keeps is_read semantics", () => {
    const db = database();
    const chat = addChat(db, "iMessage;+;fresh", null);
    addIncoming(db, chat, 500, 0);

    const snapshot = db.prepare(buildChatSnapshotQuery()).all() as Array<{ unread_count: number }>;
    assert.equal(snapshot[0].unread_count, 1);
});
