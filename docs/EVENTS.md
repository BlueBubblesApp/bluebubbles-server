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

`new-findmy-location` carries `minimumInterval: 250 ms`. Its body is ONE friend in the same
frozen `FindMyLocationItem` shape that `GET icloud/findmy/friends` lists (`FindMyInterface.legacyPayload`),
because the Flutter client parses the event and the route with one decoder. It is emitted when
the helper's pushed position changed `FindMyFriendsCache`, and not otherwise: a refresh only
asks Apple, and this event is how the answers reach a client, one device at a time. Two
properties matter:

- **Coalescing, not dropping.** Keeping the first event in a window and discarding the rest is
  right for a counter and wrong for state: a FindMy batch covering forty devices would deliver one
  position and lose thirty-nine, and the survivors would be the *oldest*. Keyed per device, the
  newest position for each is delivered, spaced.
- **Keyed per device, by the event's `handle`.** The reference emits every item of a batch that
  updated its cache, paced 250 ms apart. One key shared by
  every device let a burst of N positions through as two. The limit is on delivery to clients;
  nothing on this path reaches Apple.

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
[debug][bluebubbles] Announcing message change {attachments=false event=new-message fields= fromMe=false guid=… new=true chat=any;+;chat000000000000000001}
[debug][bluebubbles.events] Event dispatched {event=new-message lanes=3}
[debug][bluebubbles.socket] Broadcasting to sockets {connections=1 event=new-message seq=418}
[debug][bluebubbles.webhooks] Webhook delivered {event=new-message ms=143 url=https://hooks.example.com/bb?password=***}
[debug][bluebubbles.notifications] Notification handed to provider {event=new-message ms=310 provider=firebase}
```

`Event had no sink` (zero lanes) is the "events go nowhere" state; `Notification provider not
ready; skipping` and `No registered devices; not sending` are the two reasons push goes
quiet. The redaction rules for what those lines may carry are in
[`../.claude/docs/architecture.md`](../.claude/docs/architecture.md#diagnostics-logging-and-alerting-are-not-the-same-system).

### A message this server sent is announced twice, once with `tempGuid`

A client sending a message picks a `tempGuid` so it can recognise the row when it comes back.
The chat.db watcher announces every new row as a plain `new-message`, and that one carries no
`tempGuid`: the watcher cannot know which send a row belongs to. So the send itself announces
its row a second time, as `new-message` with `tempGuid` added, or as `message-send-error` with
it when the row records a failure (`MessageInterface.announceMatch`). That is the reference's
message match (`emitMessageMatch` and `emitMessageError`), sent to the
socket, push and webhooks alike.

Without it a client sees the plain event, has nothing to match it to, and draws the message a
second time when the HTTP reply lands outside its half-second match window. The match is
published before the HTTP reply returns, for text, attachment and multipart sends carrying a
`tempGuid`; the reference matches the first two only. A send whose row did not appear within
the hydration wait announces nothing extra, and its reply carries the identifiers.

### An attachment's renaming is not announced

Messages renames an attachment after the send. A sticker's row is created under a fresh UUID,
and that is the `guid` its `new-message` carries; later Messages rewrites the column to
`at_<n>_<message guid>` and keeps the first value in `original_guid`. The change detector
fingerprints message columns, and an attachment's `guid` is not one of them, so no
`updated-message` is emitted for the rename itself. A client keeps the GUID it was first
told, and that is fine: `GET /attachment/:guid` and the routes under it resolve the current
`guid` and the `originalGuid` alike, every serialised attachment carries both, and the next
`updated-message` for the message (delivered, read) carries the current one. The reasoning,
and the measurement behind it, are in
[`../.claude/docs/decisions.md`](../.claude/docs/decisions.md#an-attachment-is-found-by-either-of-its-guids-and-its-renaming-is-not-announced).

### A group change is announced twice: as its event, then as a message

A row Messages writes for a group change has no text, and its `item_type` and
`group_action_type` say what changed. When one arrives, the change detector announces the
matching group event first, then the row's `new-message`. Both are sent, as the reference
sends both: the group event makes a client refile the chat, and the `new-message` is the line
in the transcript. `ChangeDetectionService.groupEventName(for:)` holds the mapping.

| `item_type` | `group_action_type` | Event |
|---|---|---|
| 1 | 0 | `participant-added` |
| 1 | 1 | `participant-removed` |
| 2 | any | `group-name-change` |
| 3 | 0 | `participant-left` |
| 3 | 1 | `group-icon-changed` |
| 3 | 2 | `group-icon-removed` |

- **Once, when the row arrives.** A read receipt or a delivery flag that moves on the same
  row later is an `updated-message` and nothing else.
- **The socket gets the roster.** Its payload is `MessageSerializerConfig.groupEvent`: chats
  with their participants and no parsed blobs. Push and webhooks get `.notification`,
  except a rename, which gets `.notificationGroupRename` and leaves the participants out.
- **Normal priority, all six.**
- **`3/3` gets no group event.** It is the group's photo with no sender, and Messages writes
  it again, under the GUID it already has and dated now, when it resends that photo. A send
  into a group that has been quiet for a while can trigger the resend, so a client sees a
  `new-message` for a row it may already hold. The reference maps no event to `3/3` either.
  What the row is and when it reappears:
  [`.claude/docs/imessage.md`](../.claude/docs/imessage.md#group-change-rows-item_type-and-group_action_type).

`GroupEventTests` drives each pair through the real builder.

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
| Socket client | handshake query params `codecs=` and `publicKey=`, defaulting to `legacy-v1` with no key |
| Paired device | `supportedCodecs` + `publicKey` at enrollment: works with or without push |
| Push device | **not yet**: `POST /api/v1/fcm/device` reads neither field, and no push provider negotiates per device |
| Webhook / ntfy target | a per-target column in its config row |

The socket and enrollment declarations go through one parser,
`TargetCapabilities.declared` (`Sources/BBEvents/CapabilityDeclaration.swift`): the list may be
a JSON array or a comma-separated string, `legacy-v1` is always in it, and the key is base64 of
exactly 32 bytes in either the standard or the URL-safe alphabet. A socket key travels in a
query string, where a standard `+` arrives as a space, so send it URL-safe or percent-encoded.

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
  `upgradeTimeout: 30000`, and the advertised `maxPayload` of 100 MB. What a client may SEND is
  capped at 256 KB on both transports (`SocketIOTransport.maximumInbound`): the socket carries
  no client requests, only control packets and the client's heartbeat, so the reference's `maxHttpBufferSize` is not
  matched for inbound traffic.
- Handshake auth: `password` ?? `guid` from the query, decoded **exactly once**, constant-time
  compared; failure → **silent disconnect with no error event**.
- Packet encoding for `EVENT` (type 2) and `BINARY_EVENT`, default namespace `/`.
- Broadcast payloads under `legacy-v1` are the **raw object**, never envelope-wrapped.

**Nothing emits `encrypted` here, and this page used to say the opposite.** The field exists on
`ResponseEnvelope`, defaults to nil, and is emitted only when set — and no production call site
sets it. The claim that socket response envelopes still carry `encrypted: false` "because client
parsers read the field" described a delivery this server does not make.

The reference does set it on every **ack response** to an inbound
socket COMMAND — the `response(callback, channel, data)` path that answers `get-chats`,
`send-message` and the rest. This server implements none of those (see the inbound-command note
below), so there is no ack envelope for the field to sit on. The heartbeat's pong is the one
ack this server sends, and it carries `encrypted: false` as a fixed value. Socket **broadcasts**, which is
what this server does send, go out as the raw object in both servers:
the reference's `socketServer.emit(type, data)` wraps nothing. HTTP responses carry no
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

**One exception: `get-fcm-client` with an ack id is answered, with a pong.** The Flutter client
(2.1.2 and later) uses it as its liveness probe: every 30 seconds it emits the event with an ack,
waits 5 seconds, asks once more, and after a second miss tears the socket down and builds a new
one. A server that drops it costs every connected client a reconnect, and the catch-up query
after it, every 40 seconds. The answer is one argument,
`{"status":200,"message":"pong","data":null,"encrypted":false}`: the reference's ack envelope
with the FCM configuration left out, because the client never reads the argument and the
configuration stays behind the administrator-scoped `GET /api/v1/fcm/client`. A session still
waiting for its credential, and an event that asked for no ack, get nothing.
`EngineIOServer.heartbeatEvent` is where it lives, and `SocketTransportTests` pins both the
answer and the silence around it.

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
