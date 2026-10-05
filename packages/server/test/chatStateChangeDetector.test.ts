import assert from "node:assert/strict";
import test from "node:test";

import { ChatStateChangeDetector } from "../src/server/databases/imessage/pollers/ChatStateChangeDetector";
import type { ChatSnapshotEntry } from "../src/server/databases/imessage/snapshot/ChatStateSnapshot";

function entry(guid: string, overrides: Partial<ChatSnapshotEntry> = {}): ChatSnapshotEntry {
    return {
        guid,
        read: true,
        isArchived: false,
        messageCount: 1,
        readPointer: "100",
        ...overrides
    };
}

test("seed suppresses history", () => {
    const detector = new ChatStateChangeDetector();
    detector.seed([entry("a", { readPointer: "900719925474099301" })]);
    assert.deepEqual(detector.observe([entry("a", { readPointer: "900719925474099301" })]), []);
});

test("pointer regression emits unread even when message rows remain read", () => {
    const detector = new ChatStateChangeDetector();
    detector.seed([entry("a", { read: true, readPointer: "900719925474099399" })]);
    assert.deepEqual(detector.observe([entry("a", { read: true, readPointer: "900719925474099301" })]), [
        { guid: "a", read: false }
    ]);
});

test("row-derived read to unread transition emits unread", () => {
    const detector = new ChatStateChangeDetector();
    detector.seed([entry("a", { read: true })]);
    assert.deepEqual(detector.observe([entry("a", { read: false })]), [{ guid: "a", read: false }]);
});

test("pointer advance emits read only when rows say fully read", () => {
    const detector = new ChatStateChangeDetector();
    detector.seed([entry("a", { read: false, readPointer: "100" })]);
    assert.deepEqual(detector.observe([entry("a", { read: true, readPointer: "101" })]), [
        { guid: "a", read: true }
    ]);
});

test("pointer advance cannot clear a row-derived unread state", () => {
    const detector = new ChatStateChangeDetector();
    detector.seed([entry("a", { read: true, readPointer: "100" })]);
    assert.deepEqual(detector.observe([entry("a", { read: false, readPointer: "101" })]), [
        { guid: "a", read: false }
    ]);
});

test("row-derived unread to read transition emits read with unchanged pointer", () => {
    const detector = new ChatStateChangeDetector();
    detector.seed([entry("a", { read: false })]);
    assert.deepEqual(detector.observe([entry("a", { read: true })]), [{ guid: "a", read: true }]);
});

test("whole-chat deletion wins over read changes", () => {
    const detector = new ChatStateChangeDetector();
    detector.seed([entry("a", { read: false, messageCount: 2 })]);
    assert.deepEqual(detector.observe([entry("a", { read: true, messageCount: 0 })]), [
        { guid: "a", deleted: true }
    ]);
});



test("absent previously non-empty chat emits deletion once", () => {
    const detector = new ChatStateChangeDetector();
    detector.seed([entry("a", { messageCount: 5 })]);
    assert.deepEqual(detector.observe([]), [{ guid: "a", deleted: true }]);
    assert.deepEqual(detector.observe([]), []);
});

test("chat empty from seed never deletes or emits read state", () => {
    const detector = new ChatStateChangeDetector();
    detector.seed([entry("a", { messageCount: 0 })]);
    assert.deepEqual(detector.observe([]), []);
});

test("newly appearing chat seeds silently", () => {
    const detector = new ChatStateChangeDetector();
    detector.seed([]);
    assert.deepEqual(detector.observe([entry("new", { read: false, messageCount: 3, readPointer: "400" })]), []);
});

test("archive-only and unchanged snapshots emit nothing", () => {
    const detector = new ChatStateChangeDetector();
    detector.seed([entry("a", { isArchived: false })]);
    assert.deepEqual(detector.observe([entry("a", { isArchived: true })]), []);
});
