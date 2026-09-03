#!/usr/bin/env node
//  event-probe
//  Watches the event pipeline end to end: the socket and a webhook, side by side.
//
//  Nothing in the suite could answer "does a real message produce a real event, on every
//  channel, carrying what a client needs". `SocketEndToEndTests` drives the transport with
//  hand-built events and the webhook tests drive delivery with hand-built events — so both
//  halves were tested against payloads the change detector never produced. That is how every
//  emitted event came to carry `chats: []` while the whole suite stayed green.
//
//  This connects both channels to a RUNNING server, optionally triggers real activity, and
//  prints what each channel received. No dependencies: the socket is Engine.IO v4 over HTTP
//  long-polling, the same path `SocketEndToEndTests` uses, so there is no client to vendor.
//
//  Usage:
//    node Tools/event-probe/probe.mjs --password PW [--port 1234] [--seconds 45]
//                                     [--send CHAT_GUID] [--react]
//
//  It registers a webhook against itself and removes it on exit. Anything `--send` sends goes
//  to a real conversation — pass it deliberately, and only to an address cleared for testing.

import http from "node:http";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, arr) => {
    if (a.startsWith("--")) {
      const next = arr[i + 1];
      acc.push([a.slice(2), next === undefined || next.startsWith("--") ? true : next]);
    }
    return acc;
  }, [])
);

const PORT = Number(args.port ?? 1234);
const PASSWORD = args.password;
const SECONDS = Number(args.seconds ?? 45);
const HOOK_PORT = Number(args["hook-port"] ?? 34199);
const BASE = `http://127.0.0.1:${PORT}`;
if (!PASSWORD || PASSWORD === true) {
  console.error("--password is required");
  process.exit(2);
}

/** Engine.IO v4 separates frames in a polling payload with this. */
const SEPARATOR = String.fromCharCode(30);

/** Every event seen, by channel, in arrival order. */
const seen = [];
const record = (channel, name, payload) => {
  seen.push({ at: Date.now(), channel, name, payload });
  const body = payload?.data ?? payload;
  const chats = body?.chats;
  let detail = "";
  if (Array.isArray(chats)) {
    detail = `chats=${chats.length}`;
    if (chats[0]) {
      detail += Array.isArray(chats[0].participants)
        ? ` participants=${chats[0].participants.length}`
        : " participants=absent";
    }
    if (body?.handle !== undefined) detail += ` handle=${body.handle ? "yes" : "null"}`;
    if (Array.isArray(body?.attachments)) detail += ` attachments=${body.attachments.length}`;
  }
  const stamp = new Date().toISOString().slice(11, 23);
  console.log(`  ${stamp}  ${channel.padEnd(8)} ${String(name).padEnd(28)} ${detail}`);
};

const api = async (method, path, body) => {
  const joiner = path.includes("?") ? "&" : "?";
  const url = `${BASE}/api/v1${path}${joiner}password=${encodeURIComponent(PASSWORD)}`;
  const res = await fetch(url, {
    method,
    headers: body ? { "Content-Type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  try {
    return { status: res.status, body: JSON.parse(text) };
  } catch {
    return { status: res.status, body: text };
  }
};

// ---------------------------------------------------------------- webhook side

// One receiver, two roles. A webhook POSTs JSON to `/`; ntfy POSTs a text body with its
// title and priority in HEADERS to `/{topic}`, so the path is what tells them apart. Pointing
// `ntfy_server` at this process is the only way to watch the notification lane without
// Firebase credentials — and the lane, not the transport, is what is under test.
const hook = http.createServer((req, res) => {
  let raw = "";
  req.on("data", (c) => (raw += c));
  req.on("end", () => {
    const isNtfy = req.url !== "/" && req.url !== "";
    if (isNtfy) {
      record("ntfy", req.headers["title"] ?? "<no title>", { raw, headers: req.headers });
      if (process.env.PROBE_VERBOSE) {
        console.log(`      body(${raw.length}B): ${raw.slice(0, 160).replace(/\n/g, " | ")}`);
        console.log(`      priority=${req.headers["priority"]} tags=${req.headers["tags"]}`);
      }
    } else {
      try {
        const parsed = JSON.parse(raw);
        record("webhook", parsed.type ?? "?", parsed);
      } catch {
        record("webhook", "<unparseable>", { raw });
      }
    }
    res.writeHead(200).end("ok");
  });
});
await new Promise((r) => hook.listen(HOOK_PORT, "127.0.0.1", r));

// ------------------------------------------------------------------ socket side
//
// Engine.IO v4 over long-polling: handshake, join the default namespace, then poll.
// Frames: `0{…}` open, `2` ping (answer `3`), `40` namespace ack, `42[name, payload]` event.

const eio = (query) => `${BASE}/socket.io/?EIO=4&transport=polling&${query}`;

const handshake = await fetch(eio(`password=${encodeURIComponent(PASSWORD)}`));
const opening = await handshake.text();
if (!opening.startsWith("0")) {
  console.error("socket handshake failed:", opening.slice(0, 200));
  process.exit(1);
}
const sid = JSON.parse(opening.slice(1)).sid;
await fetch(eio(`sid=${sid}`), { method: "POST", body: "40" });

let polling = true;
const poll = async () => {
  while (polling) {
    try {
      const res = await fetch(eio(`sid=${sid}`));
      const text = await res.text();
      for (const frame of text.split(SEPARATOR)) {
        if (frame === "2") {
          await fetch(eio(`sid=${sid}`), { method: "POST", body: "3" });
          continue;
        }
        if (!frame.startsWith("42")) continue;
        const [name, payload] = JSON.parse(frame.slice(2));
        record("socket", name, payload);
      }
    } catch (e) {
      if (polling) console.error("  poll error:", e.message);
    }
  }
};
poll();

// --------------------------------------------------------------------- register

const created = await api("POST", "/webhook", {
  url: `http://127.0.0.1:${HOOK_PORT}/`,
  events: ["*"],
});
const webhookId = created.body?.data?.id;
console.log(`\nsocket sid=${sid}   webhook id=${webhookId} -> 127.0.0.1:${HOOK_PORT}`);
console.log(`listening ${SECONDS}s — trigger activity in Messages, or pass --send\n`);
console.log("  time          channel  event                        detail");

let cleanedUp = false;
const cleanup = async () => {
  if (cleanedUp) return;
  cleanedUp = true;
  polling = false;
  if (webhookId != null) await api("DELETE", `/webhook/${webhookId}`).catch(() => {});
  hook.close();
};

function summarise() {
  const byName = new Map();
  for (const e of seen) {
    if (!byName.has(e.name)) byName.set(e.name, new Set());
    byName.get(e.name).add(e.channel);
  }
  console.log("\n  event                          socket  webhook  ntfy");
  for (const [name, channels] of [...byName].sort()) {
    const s = channels.has("socket") ? "  yes " : "   -  ";
    const w = channels.has("webhook") ? " yes" : "  - ";
    const n = channels.has("ntfy") ? "  yes" : "   - ";
    console.log(`  ${String(name).padEnd(30)} ${s}  ${w}  ${n}`);
  }
  const withChats = seen.filter((e) => Array.isArray((e.payload?.data ?? e.payload)?.chats));
  const empty = withChats.filter((e) => (e.payload?.data ?? e.payload).chats.length === 0);
  console.log(
    `\n  ${seen.length} event(s); ${withChats.length} carried a chats array, ` +
      `${empty.length} of them empty.`
  );
}

process.on("SIGINT", async () => {
  await cleanup();
  summarise();
  process.exit(0);
});

// ---------------------------------------------------------------------- trigger

if (args.send && args.send !== true) {
  await new Promise((r) => setTimeout(r, 1500));
  const sent = await api("POST", "/message/text", {
    chatGuid: args.send,
    tempGuid: `probe-${Date.now()}`,
    message: `Event probe ${new Date().toISOString()} — please ignore`,
    method: "private-api",
  });
  console.log(`  -> sent: ${sent.status} guid=${sent.body?.data?.guid ?? "?"}`);
  if (args.react && sent.body?.data?.guid) {
    await new Promise((r) => setTimeout(r, 3000));
    const reacted = await api("POST", "/message/react", {
      chatGuid: args.send,
      selectedMessageGuid: sent.body.data.guid,
      reaction: "love",
    });
    console.log(`  -> reacted: ${reacted.status}`);
  }
}

if (args.typing && args.typing !== true) {
  await new Promise((r) => setTimeout(r, 1500));
  const guid = encodeURIComponent(args.typing);
  const on = await api("POST", `/chat/${guid}/typing`);
  console.log(`  -> typing on: ${on.status}`);
  await new Promise((r) => setTimeout(r, 2500));
  const off = await api("DELETE", `/chat/${guid}/typing`);
  console.log(`  -> typing off: ${off.status}`);
}

setTimeout(async () => {
  await cleanup();
  summarise();
  process.exit(0);
}, SECONDS * 1000);
