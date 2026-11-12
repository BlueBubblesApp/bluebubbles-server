import assert from "node:assert/strict";
import test from "node:test";

import { FCM_MAX_DATA_BYTES, fitFcmDataPayload, type FcmDataPayload } from "../src/server/services/fcmService/FcmPayload";

const envelope = (data: unknown): FcmDataPayload => ({ type: "new-message", data: JSON.stringify(data) });
const size = (payload: FcmDataPayload) => Buffer.byteLength(JSON.stringify(payload), "utf8");

const message = (overrides: Record<string, any> = {}) => ({
    guid: "message-guid",
    text: "hello",
    attachments: [],
    chats: [{ guid: "chat-guid", displayName: "Group", isFilteredAsSpam: false, participants: [] as any[] }],
    ...overrides
});

test("a payload within the limit is sent unchanged", () => {
    const payload = envelope(message());
    assert.equal(fitFcmDataPayload(payload), payload);
});

test("a large group's participant list is dropped so the message still arrives", () => {
    // Shaped like the server's serialized handles; 40 of them push a short text past 4 KB.
    const participants = Array.from({ length: 40 }, (_, i) => ({
        originalROWID: i,
        address: `+1972555${String(i).padStart(4, "0")}`,
        service: "iMessage",
        country: "us",
        uncanonicalizedId: null
    }));
    const payload = envelope(message({ chats: [{ ...message().chats[0], participants }] }));
    assert.ok(size(payload) > FCM_MAX_DATA_BYTES);

    const fitted = fitFcmDataPayload(payload);
    assert.ok(fitted && size(fitted) <= FCM_MAX_DATA_BYTES);
    const data = JSON.parse(fitted.data);
    assert.equal(data.text, "hello");
    assert.deepEqual(data.chats, [{ guid: "chat-guid", displayName: "Group", isFilteredAsSpam: false, participants: [] }]);
});

test("rich-content fields are dropped, the text is kept whole", () => {
    const text = "a long message ".repeat(150);
    const payload = envelope(
        message({
            text,
            attributedBody: [{ string: text, runs: "x".repeat(2000) }],
            attachments: [{ guid: "att", mimeType: "image/png", blurhash: "y".repeat(500) }]
        })
    );

    const fitted = fitFcmDataPayload(payload);
    assert.ok(fitted && size(fitted) <= FCM_MAX_DATA_BYTES);
    const data = JSON.parse(fitted.data);
    assert.equal(data.text, text);
    assert.equal(data.attributedBody, undefined);
    assert.deepEqual(data.attachments, [{ guid: "att", mimeType: "image/png" }]);
});

test("a message too long to fit is skipped rather than truncated", () => {
    assert.equal(fitFcmDataPayload(envelope(message({ text: "x".repeat(5000) }))), null);
});

test("the caller's payload is not modified", () => {
    const participants = Array.from({ length: 80 }, (_, i) => ({ address: `+1555000${i}` }));
    const payload = envelope(message({ chats: [{ ...message().chats[0], participants }] }));
    const original = payload.data;

    fitFcmDataPayload(payload);
    assert.equal(payload.data, original);
});
