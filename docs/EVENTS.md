# Events, sinks and payload codecs

The delivery layer: what the server emits, where it goes, and how it is encoded.
Module: `Sources/BBEvents`. Agent-facing rules: [`../.claude/docs/architecture.md`](../.claude/docs/architecture.md).

---

## Where a size limit lives

**In the transport, never above it.** FCM's 4096 bytes is Google's number and lives in
`FCMSender`, next to Google's own rejection: it measures the `data` map that actually goes on
the wire and sheds `chats[].participants` if it must, sending what fits rather than refusing
the lot. ntfy's `message-size-limit` is whatever the operator configured: its docs warn that
over 4 KB is "not recommended, and largely untested", and a UnifiedPush endpoint's belongs to
a distributor this server cannot see. A webhook has none.

It used to be a single 4000-byte cap inside `MessageSerializer`, applied to the projection that
push, webhooks and ntfy all consume. One number, wrong for every transport including FCM: it
weighed the message object plus two bytes for brackets, guessing at a wrapper it could not see.
And it never once fired, because the projection it lived in had already set
`loadChatParticipants: false`, so there was nothing left to drop.

## One sink, many providers

`NotificationSink` holds every notification transport and is routed `.push`. Firebase and ntfy
are `NotificationProvider`s attached to it as their services start.

The sink owns **routing**: which events reach notification transports at all, because that is
a parity construct: `EventRouting.policy(for:)` transcribes the reference's per-event
`sendFcmMessage` argument and is not configurable. A provider owns **everything about its own
transport**: encoding, credentials, retries, and its size limit. The payload codecs
(`legacy-v1`, `reference-v2`, `sealed-v2`) moved down with it: they describe what the
BlueBubbles client app can parse, which is nothing to do with ntfy.

Each provider declares an `EventSubscription`. `.all` is the shipping default and means
"whatever routing allows", which is what the reference sends; `.only([…])` narrows. It can
never widen, so a subscription cannot resurrect an event the reference suppresses.

**ntfy routes with push now, not with webhooks.** It is a Firebase replacement: someone
configuring it is leaving Google, not subscribing a URL. It still receives
`typing-indicator` and `new-findmy-location`, as it did under v1 where it is a webhook: those
two are declined by **`FirebaseProvider.referenceSubscription`**, not by the bus.

That distinction is the whole reason subscriptions exist. The reference passes
`sendFcmMessage: false` for exactly those two events, and that is a fact about Firebase: it
delivers both to webhooks quite happily. Applied at the bus, as `EventRouting(allowsPush:
false)`, it read as a rule about notifications in general and silently took them from every
transport that later joined the push lane. `allowsPush` is the class gate and is
open for every event; a suppression that genuinely applied to *every* notification
transport would belong there.

The move also removes a live inconsistency: the same ntfy topic used to get a different event
set depending on whether it was configured as a webhook or through its own settings.

## `ServerEvent`

One vocabulary, client-facing and wire-constrained: **every case exists because a client
consumes it.** `Sources/BBEvents/ServerEvent.swift`.

Socket.IO event names are `kebab-case` and **frozen**. Adding a case means adding a name clients
will see, so it is additive surface subject to the compatibility contract.

### Routing policy

`EventRouting.policy(for:)` declares per-event delivery. Two events suppress push while keeping
the socket, and both have a reason that is not obvious:

| Event | Socket | Push | Webhooks | Why |
|---|---|---|---|---|
| `typing-indicator` | yes | **no** | yes | An indicator delivered through push arrives *after* the message it was announcing, which is worse than not sending it |
| `new-findmy-location` | yes | **no** | yes | Location updates arrive in bursts and would burn FCM quota |
| everything else | yes | yes | yes | |

**Webhooks have no suppression flag at all**: every event reaches subscribed webhooks.

### Rate limiting coalesces; it does not drop

`new-findmy-location` carries `minimumInterval: 250 ms`. Two properties matter:

- **Coalescing, not dropping.** Keeping the first event in a window and discarding the rest is
  right for a counter and wrong for state: a FindMy batch covering forty devices would deliver one
  position and lose thirty-nine, and the survivors would be the *oldest*. Keyed per device, the
  newest position for each is delivered, spaced.
- **This one limit is global, not keyed.** Everywhere else the limiter keys per chat or device so
  a busy one cannot starve a quiet one. FindMy is deliberately different: the server is a single
  FindMy client as far as Apple is concerned, and keying per device would multiply the permitted
  rate by the number of devices: exactly the pressure the limit exists to avoid. It is the
  *rate* that is capped, not the freshness.

The 250 ms spacing is expressed as policy rather than a `sleep` in the emit loop. A sleep blocks
the whole handler, so a 40-device batch stalls processing for ten seconds.

---

## Sinks

```swift
public protocol EventSink: Sendable {
    var routing: SinkRouting { get }        // no default: a sink says which rules it follows
    var id: SinkID { get }
    var projection: PayloadProjection { get }   // socket takes .full, everything else .notification
    func accepts(_ event: ServerEvent) async -> Bool
    func deliver(_ event: ServerEvent) async throws
}
```

**Every sink is independently optional, and there is no primary delivery route.** A socket-only
install, a webhook-only install and a full FCM install are all first-class, and none of them
should warn about the sinks it does not have.

| Sink | Enabled by | Notes |
|---|---|---|
| socket | always | The only route many desktop (Linux/Windows) clients use |
| push | a Firebase config being present | **Optional.** No config means the sink is simply not registered: not a degraded state |
| `WebhookSink` | any configured webhook | Per-webhook event subscription |
| `NtfyProvider` | a configured ntfy target | Maps the event onto ntfy's actual header protocol: title, body, priority, tags, click action, auth token, self-hosted server URL |

### A webhook's redirect policy is per-target and off by default

`URLSession` follows redirects unless a delegate refuses, so the URL an operator registered was
never the only address that could receive their messages: a `302` from an approved endpoint
re-points the POST — message content and all — at anything this server can reach, loopback
included. A webhook is registrable by anything holding the server password, so that is a
decision worth making explicitly.

`webhook.follow_redirects` is the column, `followRedirects` the wire key (on the create and
update bodies and on every webhook in the list), and a switch beside the URL in the settings
window. Three rules:

- **A new webhook is `false`.** A redirect is reported as a failed delivery — `HTTP 302` in the
  webhook's row — rather than followed, which names the endpoint and the fix at once.
- **A webhook that predates the column is `true`**, backfilled by the migration's DDL default.
  Those endpoints have been following redirects for as long as they have existed and an upgrade
  is not the place to change what a working integration does.
- **Absent means "leave it".** `createWebhook` upserts on the URL, so a v1 client
  re-registering after a reinstall sends the two fields it has always sent; reading that as
  `false` would disarm the switch through a request that was not about redirects.

ntfy is `true` and has no switch: its endpoint is typed into the settings window by the
operator, ntfy.sh redirects by design, and there is no per-target row to hang a toggle on.

### A webhook can be narrowed to chosen conversations

A webhook's event list says WHICH events it receives; its chat filter says, for the events
about a conversation, WHOSE. `webhook.chat_guids` is the column: a JSON array of chat GUIDs, or
NULL for every conversation. The settings window sets it in a Conversations section that
appears only while the chosen events include a chat event, and `WebhookTarget.chatScope`
carries it to `WebhookSink`.

- **The filter narrows chat events and leaves the rest alone.** `EventName.chatScoped` is the
  set it applies to: the message events (new, updated, send error), the group events, typing,
  read state and scheduled-message outcomes. A server update or a FindMy location reaches a
  filtered webhook exactly as it reaches any other.
- **The chat is read from the event's full payload**, by `ServerEvent.chatGUIDs`, the one
  place that knows where each event keeps it. The full payload, because the notification
  projection of `updated-message` leaves its chats out for Firebase's 4 KB cap.
- **GUIDs are compared with `ChatGUID.sameChat`.** A filter saved before macOS 26 holds
  `iMessage;-;…` and the events after the upgrade carry `any;-;…` for the same chat.
- **Fail closed.** A chat event whose chat cannot be read, and a stored list that cannot be
  decoded, are withheld from a filtered webhook rather than delivered: a filter that let
  through what it cannot identify would deliver exactly the conversations it was set up to
  keep out.
- **It is not on the v1 wire.** `GET /webhook` does not report it and the create and update
  routes do not take it, so absent means "leave it", as it does for `followRedirects`: a client
  re-registering after a reinstall does not widen an endpoint the operator narrowed. Putting it
  on the wire is an addition to the contract, which `acceptedDifferences` would have to declare.

### A webhook retries failed deliveries, in order, off the lane

`webhook.retry_limit` and `webhook.retry_delay_seconds` are the policy (`WebhookRetryPolicy`):
how many retries one event gets after its first attempt, and the wait before the first retry,
doubling after each failure up to an hour, with jitter of a fifth either way. A new webhook
gets `Webhook.defaultRetryPolicy` (five retries from 30 seconds, about a quarter of an hour in
all); a webhook that predates the columns gets none, because an upgrade does not start sending
an endpoint second attempts it never asked for. Absent in a write means "leave it", as for the
redirect policy, and like the chat filter it is set from the settings window and is not on the
v1 wire.

- **Retries never run in the lane.** The bus delivers to `WebhookSink` one event at a time, so
  the lane only ever makes a first attempt. A retryable failure opens that endpoint's outbox
  (`WebhookOutboxes`), and the outboxes are drained by their own tasks, one per endpoint, woken
  by a single timer set for whichever is due first.
- **An endpoint with an open outbox is not sent new events directly.** They queue behind the
  failed one, so the endpoint receives events in the order they happened, is not sent a burst
  while it is down, and an endpoint that hangs costs one 15-second timeout rather than one per
  event. When the head gets through, the rest follow at once. Other endpoints are unaffected.
- **Only what a later attempt could change is retried**: timeouts, connection failures, HTTP
  408, 425, 429 and 5xx. Any other response says the request itself was refused, and the event
  is given up on at once without moving the backoff. A typing indicator is never retried or
  queued, because it is stale by the time a retry could land.
- **Every attempt carries two headers.** `X-BlueBubbles-Delivery-Id` is the same on every
  attempt at one event, so a receiver can drop a duplicate (the one a retry cannot avoid: the
  work was done and the response was lost); `X-BlueBubbles-Delivery-Attempt` counts from 1.
  Headers rather than a body field, because the body is `{"type", "data"}` and consumers parse
  it.
- **Bounded and in memory.** An outbox holds at most 500 events and drops the oldest past that,
  saying so once. A service stop discards every outbox and logs how many events were waiting.
- **The webhooks page says what is waiting.** `WebhookDeliveryState.waiting` and
  `nextAttemptAt` put "3 events waiting to retry, next attempt in 2 minutes" on the row. The
  persistent-failure alert counts attempts, retries included.

Not done: honouring `Retry-After` on a 429 or 503 (the transport reports the status alone), and
keeping outboxes across a restart.

**Registration is the on-switch.** `EventBus.register(_:)` is what makes a sink active; an
unconfigured sink is *not registered*, never registered-and-disabled. That distinction is what
keeps "no Firebase" a valid deployment rather than a warning state.

Setup and health checks must have a **no-push-provider path**: a socket-only or webhook-only
install completes setup with no Firebase prompt and no warning banner.

### `emit` does not protect the caller

`EventBus.emit` returns once every sink has finished **or timed out** (30 s default). There is no
subscriber buffering and no backpressure valve.

**`emit` never waits for delivery.** Each sink has its own lane: a serial queue with a
per-event timeout, so the caller returns once the event is queued, order is kept per sink,
and a slow webhook delays only itself. Tests that need to observe delivery call
`bus.settle()`; shutdown calls `flushPending()`, which flushes the rate limiter and settles.
Delivery latency is a sink's problem, never the detector's.

Delivery failures are **logged, not raised**. One failed webhook POST is not worth interrupting
anyone over, and the sink itself raises once a failure becomes persistent: it is the only thing
that knows the difference.

### Following one message through the log

At `log_level = debug` a delivery reads as one line per stage, each carrying the event name
and the message GUID where it has one, so a support log answers "what happened to that
message" without a debugger:

```
[debug][bluebubbles.change-detector] chat.db changes detected {examined=41 new=1 pass=fast tick=212 updated=0}
[debug][bluebubbles] Announcing message change {attachments=false event=new-message fields= fromMe=false guid=… new=true room=-}
[debug][bluebubbles.events] Event dispatched {event=new-message lanes=3}
[debug][bluebubbles.socket] Broadcasting to sockets {connections=1 event=new-message seq=418}
[debug][bluebubbles.webhooks] Webhook delivered {event=new-message ms=143 url=https://hooks.example.com/bb?password=***}
[debug][bluebubbles.notifications] Notification handed to provider {event=new-message ms=310 provider=firebase}
```

`Event had no sink` (zero lanes) is the "events go nowhere" state; `Notification provider not
ready; skipping` and `No registered devices; not sending` are the two reasons push goes
quiet. The redaction rules for what those lines may carry are in
[`../.claude/docs/architecture.md`](../.claude/docs/architecture.md#diagnostics-logging-and-alerting-are-not-the-same-system).

---

## Payload codecs

Encoding is the final stage of delivery, behind a protocol, so **no event producer changes when
the codec changes**:

```swift
public protocol EventPayloadCodec: Sendable {
    var identifier: CodecIdentifier { get }
    // `projection` decides full-vs-trimmed; the codec decides encoding. Keeping them apart
    // is what lets a sealed FCM payload and a plaintext socket frame carry the same event.
    func encode(
        _ event: ServerEvent,
        projection: PayloadProjection,
        capabilities: TargetCapabilities
    ) async throws -> EncodedPayload
}
```

### `legacy-v1`: the default

Full serialized objects. Push gets `{type, data: <stringified JSON>}`; the socket gets the raw
object, never envelope-wrapped. **This is the default for every target and does not move.**

### `reference-v2`: identifiers only, client hydrates

`{"v":2,"t":"new-message","g":"<guid>","c":"<chatGuid>","ts":1740000000}`

- Message content never transits Google's infrastructure, so there is **no key management problem
  to get wrong**.
- Fits under the 4096-byte FCM ceiling that otherwise forces participants to be stripped from
  notifications.
- Socket and push converge on one envelope, so the socket stops being a second serialization path.
- **Honest downsides:** the client cannot render a notification body without a round trip, so a
  notification arriving while the Mac is asleep or the tunnel is down shows nothing useful;
  latency grows by one request; Android background-fetch restrictions make hydration non-trivial.
- **It hides content, not metadata.** A chat GUID *is* the counterparty's address, and the client
  needs it to route the notification, so it cannot be withheld. Anyone who can read the push
  payload still learns **who you are talking to and when**: just not what was said. Say this
  plainly; "content never transits Google" is easy to hear as "nothing does".
- Mitigations: a configurable hint set (`.none` | `.senderOnly` | `.senderAndPreview`), and a
  batch `POST /api/v1/message/hydrate {guids: [...]}` so a burst of notifications costs one
  request.

### `sealed-v2`: full payload, end-to-end encrypted

Layered **on top of** the reference-v2 envelope rather than replacing it: routing metadata stays
plaintext, the body is sealed, and the two can mix. Hiding the metadata too is what this adds over
`reference-v2`: the whole body, chat GUID included, is inside the ciphertext and only the event
name stays visible.

- **X25519 key agreement + ChaCha20-Poly1305** via swift-crypto. The device generates a keypair at
  registration and submits its public key; **each message uses a fresh ephemeral server key**,
  giving per-message forward secrecy.
- Envelope: `{"v":2,"t":"new-message","alg":"x25519-chacha20poly1305","epk":"…","n":"…","ct":"…"}`.
- Devices registered without a public key transparently fall back to `reference-v2`.

### Negotiation is per-delivery-target, not a global flip

This is what makes an alternate codec deployable against a mixed fleet. It must not assume push
registration is where capability is declared: many installs have no push at all.

| Target | Declares capability via |
|---|---|
| Socket client | handshake query param `codecs=`, defaulting to `legacy-v1` |
| Paired device | `supportedCodecs` + `publicKey` at enrollment: works with or without push |
| Push device | optional `supportedCodecs` / `publicKey` on `POST /api/v1/fcm/device` |
| Webhook / ntfy target | a per-target column in its config row |

The server resolves `min(serverPreference, targetSupport)` at delivery time, so **one event can
produce a `legacy-v1` socket frame, a `sealed-v2` push payload and a `legacy-v1` webhook POST in
the same fan-out**. `event_payload_codec` is the server's *preference ceiling* and defaults to
`legacy-v1`. `GET /api/v1/server/info` advertises `supported_payload_codecs` and `payload_codec`.

Webhook and ntfy targets keep a per-target setting deliberately: a self-hosted consumer on the
same LAN has entirely different trust properties from Google's push infrastructure, so it can stay
on `legacy-v1` while push moves to `sealed-v2`.

`reference-v2`'s round-trip cost is also asymmetric: a desktop client on an open socket hydrates
instantly, while an Android device woken by a data-only push pays real latency and
background-execution cost. Per-target selection lets each pick what suits it.

**Both alternates are default-off and stay that way** until clients can decrypt or hydrate. See
[`../.claude/docs/decisions.md`](../.claude/docs/decisions.md).

---

## Socket delivery

`Sources/BBSocketIO` is a native Engine.IO / Socket.IO implementation, sharing the same NIO HTTP
server as the REST API.

**Must be exact:**

- Engine.IO handshake over **both** polling and websocket, with **EIO3 and EIO4**: the
  equivalent of `allowEIO3: true` is load-bearing for older Flutter clients.
- Transport upgrade (polling → websocket), `pingInterval: 60000`, `pingTimeout: 120000`,
  `upgradeTimeout: 30000`, `maxHttpBufferSize: 100MB`.
- Handshake auth: `password` ?? `guid` from the query, decoded **exactly once**, constant-time
  compared; failure → **silent disconnect with no error event**.
- Packet encoding for `EVENT` (type 2) and `BINARY_EVENT`, default namespace `/`.
- Broadcast payloads under `legacy-v1` are the **raw object**, never envelope-wrapped.

**Nothing emits `encrypted` here, and this page used to say the opposite.** The field exists on
`ResponseEnvelope`, defaults to nil, and is emitted only when set — and no production call site
sets it. The claim that socket response envelopes still carry `encrypted: false` "because client
parsers read the field" described a delivery this server does not make.

The reference does set it, at `socketRoutes.ts:57`, on every **ack response** to an inbound
socket COMMAND — the `response(callback, channel, data)` path that answers `get-chats`,
`send-message` and the rest. This server implements none of those (see the inbound-command note
above), so there is no ack envelope for the field to sit on. Socket **broadcasts**, which is
what this server does send, go out as the raw object in both servers:
`socketServer.emit(type, data)` at `index.ts:1169` wraps nothing. HTTP responses carry no
`encrypted` in either server either.

So it is not a missing field today. It becomes one the moment the inbound command surface is
implemented, and that is the note to carry forward: whoever builds it must set
`encrypted: false` on every ack, because the reference does unconditionally.

### Replay is strictly opt-in

The server maintains a monotonic sequence and a bounded in-memory ring of recent events
(size-capped, minutes not hours).

Adding a `seq` field to broadcast payloads would alter every event body, so **it is not added by
default.** A client opts in with `replay=1` in the handshake, and only then receives `seq` and
gains `?since=<seq>` reconnection; overflow or an unknown `seq` yields a `resync-required` marker
so it falls back to a full fetch. **For every client that does not ask, broadcast payloads are
byte-identical**: the ring is maintained and never consulted.

### Inbound commands

Clients drive the server over HTTP; the socket is server→client events only. An unrecognised
inbound event is **ignored rather than answered**.

If the ~33 legacy inbound commands are ever needed, they adapt over the same interfaces the HTTP
handlers use: no business logic is duplicated. Quirks to preserve if so: `get-vcf` and
`check-for-server-update` both ack on channel **`save-vcf`**; `attachment-chunk` is never
encrypted; the presence of a client ack callback changes delivery from channel-emit to callback.

---

## Extending delivery

`CustomEventSink` is the extension point. `WebhookSink` is written against it
rather than being special-cased, which is what keeps the surface honest: if it cannot express the
built-ins, it is not good enough.

A new delivery route is a new sink: conform, declare a `SinkID` **and a `SinkRouting`**, and
register it. Registration is the on-switch, so a sink with no configuration is simply never
registered.

`SinkRouting` (`.socket`, `.push` or `.webhook`) is which suppression rules the sink obeys,
and it deliberately has no default. The bus used to infer it by switching on `SinkID`, which
is a string wrapper, so the switch needed a `default` and every sink outside the four known
constants silently inherited webhook routing. Saying which class you are in is one line;
inheriting the wrong one is invisible.
