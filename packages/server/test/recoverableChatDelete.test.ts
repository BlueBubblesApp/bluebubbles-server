import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { recoverableChatDeleteRequest } from "../src/server/api/privateApi/protocol/RecoverableChatDeleteRequest";

const source = (relativePath: string) => readFileSync(new URL(relativePath, import.meta.url), "utf8");

test("builds only the dedicated recoverable-delete private API request", () => {
    const request = recoverableChatDeleteRequest("chat-guid");

    assert.deepEqual(request, {
        action: "recoverable-delete-chat",
        data: { chatGuid: "chat-guid" }
    });
    assert.notEqual(request.action, "delete-chat");
});

test("private API chat exposes a dedicated recoverable method without changing permanent delete", () => {
    const code = source("../src/server/api/privateApi/apis/PrivateApiChat.ts");
    const method = code.match(/async recoverableDelete[\s\S]*?\n    \}/u)?.[0] ?? "";

    assert.match(method, /recoverableChatDeleteRequest\(guid\)/);
    assert.match(method, /throwForNoMissingFields\(action, \[guid\]\)/);
    assert.match(method, /TransactionPromise\(TransactionType\.CHAT\)/);
    assert.match(method, /sendApiMessage\(action, data, request\)/);
    assert.doesNotMatch(method, /"delete-chat"/);
    assert.match(code, /async delete\(guid: string\)[\s\S]*?const action = "delete-chat";/);
});

test("chat interface guards recoverable deletion by private API and macOS version", () => {
    const code = source("../src/server/api/interfaces/chatInterface.ts");
    const method = code.match(/static async recoverableDelete[\s\S]*?\n    \}/u)?.[0] ?? "";

    assert.match(method, /checkPrivateApiStatus\(\)/);
    assert.match(method, /isMinVentura/);
    assert.match(method, /privateApi\.chat\.recoverableDelete\(guid\)/);
    assert.doesNotMatch(method, /privateApi\.chat\.delete\(/);
});

test("chat interface fails when the helper never received the recoverable delete", () => {
    const code = source("../src/server/api/interfaces/chatInterface.ts");
    const method = code.match(/static async recoverableDelete[\s\S]*?\n    \}/u)?.[0] ?? "";

    // sendApiMessage returns null instead of throwing on socket write failure
    assert.match(method, /const result = await Server\(\)\.privateApi\.chat\.recoverableDelete\(guid\)/);
    assert.match(method, /if \(!result\) \{\s*throw new Error\(/u);
});

test("controller propagates recoverable deletion through its dedicated interface method", () => {
    const code = source("../src/server/api/http/api/v1/routers/chatRouter.ts");
    const method = code.match(/static async recoverableDeleteChat[\s\S]*?\n    \}/u)?.[0] ?? "";

    assert.match(method, /await ChatInterface\.recoverableDelete\(guid\)/);
    assert.match(method, /Successfully recoverably deleted chat!/);
    assert.doesNotMatch(method, /ChatInterface\.delete\(/);
    assert.doesNotMatch(method, /catch\s*\(/, "errors must propagate to the HTTP error middleware");
});

test("HTTP routes dedicate POST /chat/:guid/delete/recoverable and preserve permanent DELETE", () => {
    const code = source("../src/server/api/http/api/v1/httpRoutes.ts");

    assert.match(
        code,
        /method: HttpMethod\.POST,\s*path: ":guid\/delete\/recoverable",\s*middleware: \[\.\.\.HttpRoutes\.protected, PrivateApiMiddleware\],\s*controller: ChatRouter\.recoverableDeleteChat/u
    );
    assert.match(
        code,
        /method: HttpMethod\.DELETE,\s*path: ":guid",\s*middleware: \[\.\.\.HttpRoutes\.protected, PrivateApiMiddleware\],\s*controller: ChatRouter\.deleteChat/u
    );
});
