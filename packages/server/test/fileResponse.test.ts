import assert from "node:assert/strict";
import { validateHeaderValue } from "node:http";
import test from "node:test";

import { attachmentContentDisposition } from "../src/server/api/http/api/v1/responses/success";

test("encodes Unicode attachment filenames without emitting non-ASCII header bytes", () => {
    const header = attachmentContentDisposition("Photo 6:20\u202fPM.png");

    assert.equal(
        header,
        "attachment; filename=\"Photo 6:20_PM.png\"; filename*=UTF-8''Photo%206%3A20%E2%80%AFPM.png"
    );
    assert.match(header, /^[\x20-\x7e]+$/);
});

test("preserves the existing header for safe ASCII filenames", () => {
    assert.equal(attachmentContentDisposition("photo.png"), 'attachment; filename="photo.png"');
});

test("sanitizes header-breaking characters while retaining the encoded filename", () => {
    const header = attachmentContentDisposition('report"\r\nX-Test: injected\\name.png');

    assert.doesNotThrow(() => validateHeaderValue("Content-Disposition", header));
    assert.equal(
        header,
        "attachment; filename=\"report___X-Test: injected_name.png\"; " +
            "filename*=UTF-8''report%22%0D%0AX-Test%3A%20injected%5Cname.png"
    );
});

test("normalizes unpaired UTF-16 surrogates without throwing", () => {
    assert.doesNotThrow(() => attachmentContentDisposition("broken-\ud800-\udc00.png"));
    assert.equal(
        attachmentContentDisposition("broken-\ud800-\udc00.png"),
        "attachment; filename=\"broken-_-_.png\"; filename*=UTF-8''broken-%EF%BF%BD-%EF%BF%BD.png"
    );
});
