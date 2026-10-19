const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { EventEmitter } = require("node:events");
const ts = require("../packages/server/node_modules/typescript");
const root = path.resolve(__dirname, "../packages/server/src/server");

// Load production TypeScript with explicit boundary mocks. Never import the
// Electron entrypoint, connect to Messages, or access the user's databases.
function load(file, deps = {}) {
  const filename = path.join(root, file);
  const js = ts.transpileModule(fs.readFileSync(filename, "utf8"), {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2020,
    },
  }).outputText;
  const mod = { exports: {} };
  const req = (name) => {
    if (Object.hasOwn(deps, name)) return deps[name];
    throw new Error(`Unexpected dependency ${name} in ${file}`);
  };
  vm.runInThisContext(`(function(require,module,exports){${js}\n})`, {
    filename,
  })(req, mod, mod.exports);
  return mod.exports;
}
const protocol = load("utils/ReactionUtils.ts");
const unicode = ["💙", "🤣", "👍🏽", "👩🏽‍💻", "👨‍👩‍👧‍👦", "🇺🇸", "1️⃣", "#️⃣", "🏳️‍🌈", "🫩"];

test("classic add/remove works without custom helper", () => {
  for (const name of [
    "love",
    "like",
    "dislike",
    "laugh",
    "emphasize",
    "question",
  ]) {
    for (const prefix of ["", "-"])
      assert.deepEqual(protocol.requireReactionSupport(prefix + name, false), {
        reactionType: prefix + name,
      });
  }
});
test("Unicode sequences survive add/remove and serialization", () => {
  for (const emoji of unicode) {
    assert.deepEqual(protocol.requireReactionSupport(emoji, true), {
      reactionType: "emoji",
      reactionEmoji: emoji,
    });
    assert.deepEqual(protocol.requireReactionSupport("-" + emoji, true), {
      reactionType: "-emoji",
      reactionEmoji: emoji,
    });
    for (const kind of ["emoji", "2006"])
      assert.equal(protocol.serializeReactionType(kind, emoji), emoji);
    for (const kind of ["-emoji", "3006"])
      assert.equal(protocol.serializeReactionType(kind, emoji), "-" + emoji);
  }
  assert.equal(protocol.serializeReactionType("love", "💙"), "love");
});
test("invalid, multi-emoji, text and unsupported sends fail", () => {
  for (const bad of [
    "",
    "-",
    "abc",
    "emoji",
    "mxc://example/image",
    "🔥🔥",
    "text🔥",
    " 🔥",
    "🔥\n",
    "🇺",
    "1",
    "\ud800",
    "🔥".repeat(100),
  ]) {
    assert.throws(() => protocol.parseReaction(bad), undefined, bad);
  }
  for (const emoji of unicode)
    assert.throws(
      () => protocol.requireReactionSupport(emoji, false),
      /helper/
    );
});

class FakeAction {
  constructor(api) {
    this.api = api;
  }
  throwForNoMissingFields() {}
  async sendApiMessage(action, data) {
    this.api.sent.push({ action, data });
    return { identifier: "reaction-id" };
  }
}
const { PrivateApiMessage } = load("api/privateApi/apis/PrivateApiMessage.ts", {
  ".": { PrivateApiAction: FakeAction },
  "@server/utils/ReactionUtils": protocol,
  "@server/managers/transactionManager/transactionPromise": {
    TransactionPromise: class {},
    TransactionType: { MESSAGE: "message" },
  },
  "@server/env": { isMinCatalina: true, isMinMonterey: true },
});
test("production private-API adapter sends exact helper contract", async () => {
  const api = { customEmojiReactions: true, sent: [] };
  const adapter = new PrivateApiMessage(api);
  for (const emoji of unicode) {
    for (const remove of [false, true]) {
      const response = await adapter.react(
        "chat",
        "message",
        (remove ? "-" : "") + emoji,
        2
      );
      assert.equal(response.identifier, "reaction-id");
      assert.deepEqual(api.sent.pop(), {
        action: "send-reaction",
        data: {
          chatGuid: "chat",
          selectedMessageGuid: "message",
          partIndex: 2,
          reactionType: remove ? "-emoji" : "emoji",
          reactionEmoji: emoji,
        },
      });
    }
  }
  api.customEmojiReactions = false;
  await assert.rejects(adapter.react("chat", "message", "🔥"), /helper/);
  assert.equal(api.sent.length, 0);
  await adapter.react("chat", "message", "-like");
  assert.equal(api.sent[0].data.reactionType, "-like");
});

class FakeLoggable extends EventEmitter {
  get log() {
    return { debug() {}, info() {} };
  }
}
const serviceFile = "api/privateApi/PrivateApiService.ts";
const serviceDeps = {};
const serviceSrc = fs.readFileSync(path.join(root, serviceFile), "utf8");
for (const [, name] of serviceSrc.matchAll(/from\s+["']([^"']+)["']/g))
  serviceDeps[name] = {};
serviceDeps["@server/lib/logging/Loggable"] = { Loggable: FakeLoggable };
serviceDeps["../../lib/logging/Loggable"] = { Loggable: FakeLoggable };
serviceDeps["async-sema"] = { Sema: class {} };
const { PrivateApiService } = load(serviceFile, serviceDeps);
test("capability is tied to the active Messages helper and clears on disconnect", () => {
  const service = Object.create(PrivateApiService.prototype);
  service.activeClients = {};
  service.clients = [];
  service.emit = () => {};
  const socket = { id: "one", destroyed: false };
  service.clients.push(socket);
  service.registerClient("com.apple.MobileSMS", socket);
  assert.equal(service.customEmojiReactions, false);
  service.registerClient("com.apple.MobileSMS", socket, {
    custom_emoji_reactions: "true",
  });
  assert.equal(service.customEmojiReactions, false);
  service.registerClient("com.apple.MobileSMS", socket, {
    custom_emoji_reactions: true,
  });
  assert.equal(service.customEmojiReactions, true);
  socket.destroyed = true;
  assert.equal(service.customEmojiReactions, false);
  socket.destroyed = false;
  service.removeClient(socket);
  assert.equal(service.customEmojiReactions, false);
  service.registerClient(
    "com.apple.FaceTime",
    { id: "two", destroyed: false },
    { custom_emoji_reactions: true }
  );
  assert.equal(service.customEmojiReactions, false);
});

const validatorDeps = {};
const validatorFile = "api/http/api/v1/validators/messageValidator.ts";
const validatorSrc = fs.readFileSync(path.join(root, validatorFile), "utf8");
for (const [, name] of validatorSrc.matchAll(/from\s+["']([^"']+)["']/g))
  validatorDeps[name] = {};
const server = { privateApi: { customEmojiReactions: true } };
validatorDeps["@server"] = { Server: () => server };
validatorDeps["./index"] = { ValidateInput() {} };
validatorDeps["../responses/errors"] = {
  BadRequest: class extends Error {
    constructor({ error }) {
      super(error);
    }
  },
};
validatorDeps["@server/utils/ReactionUtils"] = protocol;
const { MessageValidator } = load(validatorFile, validatorDeps);
test("REST validator blocks invalid and unsupported reactions before dispatch", async () => {
  let called = 0;
  await MessageValidator.validateReaction(
    { request: { body: { reaction: "👍🏽" } } },
    async () => called++
  );
  assert.equal(called, 1);
  for (const reaction of ["hello", "🔥🔥", "-"])
    await assert.rejects(
      MessageValidator.validateReaction(
        { request: { body: { reaction } } },
        async () => called++
      )
    );
  server.privateApi.customEmojiReactions = false;
  await assert.rejects(
    MessageValidator.validateReaction(
      { request: { body: { reaction: "🔥" } } },
      async () => called++
    ),
    /helper/
  );
  assert.equal(called, 1);
});

const generalDeps = {};
const generalFile = "api/interfaces/generalInterface.ts";
for (const [, name] of fs
  .readFileSync(path.join(root, generalFile), "utf8")
  .matchAll(/from\s+["']([^"']+)["']/g))
  generalDeps[name] = {};
const metadataServer = {
  computerIdentifier: "test",
  repo: { getConfig: () => true },
  privateApi: { customEmojiReactions: true, helper: {} },
  iMessageRepo: { getiMessageAccount: async () => "" },
};
generalDeps.electron = { app: { getVersion: () => "test" } };
generalDeps["macos-version"] = { default: () => "26.0" };
generalDeps["@server"] = { Server: () => metadataServer };
generalDeps["@server/fileSystem"] = {
  FileSystem: {
    getIcloudAccount: async () => "",
    getTimeSync: async () => true,
    getLocalIps: () => [],
  },
};
const { GeneralInterface } = load(generalFile, generalDeps);
test("server metadata exposes only a strict advertised helper capability", async () => {
  assert.equal(
    (await GeneralInterface.getServerMetadata()).custom_emoji_reactions,
    true
  );
  metadataServer.privateApi.customEmojiReactions = false;
  assert.equal(
    (await GeneralInterface.getServerMetadata()).custom_emoji_reactions,
    false
  );
  metadataServer.privateApi = undefined;
  assert.equal(
    (await GeneralInterface.getServerMetadata()).custom_emoji_reactions,
    false
  );
});

const messageDeps = {};
const messageFile = "api/interfaces/messageInterface.ts";
for (const [, name] of fs
  .readFileSync(path.join(root, messageFile), "utf8")
  .matchAll(/from\s+["']([^"']+)["']/g))
  messageDeps[name] = {};
messageDeps["@server"] = {
  Server: () => ({ privateApi: { customEmojiReactions: false } }),
};
messageDeps["@server/utils/ReactionUtils"] = protocol;
for (const key of Object.keys(messageDeps)) {
  if (/helpers\/utils$/.test(key))
    messageDeps[key] = { checkPrivateApiStatus() {} };
}
const { MessageInterface } = load(messageFile, messageDeps);
test("shared send path rejects Socket.IO/direct callers before remote dispatch", async () => {
  await assert.rejects(
    MessageInterface.sendReaction({
      chatGuid: "chat",
      message: {},
      reaction: "🔥",
    }),
    /helper/
  );
});
