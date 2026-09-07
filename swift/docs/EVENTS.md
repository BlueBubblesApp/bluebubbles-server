# Events, sinks and payload codecs

The delivery layer: what the server emits, where it goes, and how it is encoded.
Module: `Sources/BBEvents`. Agent-facing rules: [`../.claude/docs/architecture.md`](../.claude/docs/architecture.md).

---

## Where a size limit lives

**In the transport, never above it.** FCM's 4096 bytes is Google's number and lives in
`FCMSender`, next to Google's own rejection: it measures the `data` map that actually goes on
the wire and sheds `chats[].participants` if it must, sending what fits rather than refusing
the lot. ntfy's `message-size-limit` is whatever the operator configured — its docs warn that
over 4 KB is "not recommended, and largely untested" — and a UnifiedPush endpoint's belongs to
a distributor this server cannot see. A webhook has none.

It used to be a single 4000-byte cap inside `MessageSerializer`, applied to the projection that
push, webhooks and ntfy all consume. One number, wrong for every transport including FCM: it
weighed the message object plus two bytes for brackets, guessing at a wrapper it could not see.
And it never once fired, because the projection it lived in had already set
`loadChatParticipants: false`, so there was nothing left to drop.

## One sink, many providers

`NotificationSink` holds every notification transport and is routed `.push`. Firebase and ntfy
are `NotificationProvider`s attached to it as their services start.

The sink owns **routing** — which events reach notification transports at all — because that is
a parity construct: `EventRouting.policy(for:)` transcribes the reference's per-event
`sendFcmMessage` argument and is not configurable. A provider owns **everything about its own
transport**: encoding, credentials, retries, and its size limit. The payload codecs
(`legacy-v1`, `reference-v2`, `sealed-v2`) moved down with it — they describe what the
BlueBubbles client app can parse, which is nothing to do with ntfy.

Each provider declares an `EventSubscription`. `.all` is the shipping default and means
"whatever routing allows", which is what the reference sends; `.only([…])` narrows. It can
never widen, so a subscription cannot resurrect an event the reference suppresses.

**ntfy routes with push now, not with webhooks.** It is a Firebase replacement — someone
configuring it is leaving Google, not subscribing a URL. It still receives
`typing-indicator` and `new-findmy-location`, as it did under v1 where it is a webhook: those
two are declined by **`FirebaseProvider.referenceSubscription`**, not by the bus.

That distinction is the whole reason subscriptions exist. The reference passes
`sendFcmMessage: false` for exactly those two events, and that is a fact about Firebase — it
delivers both to webhooks quite happily. Applied at the bus, as `EventRouting(allowsPush:
false)`, it read as a rule about notifications in general and silently took them from every
transport that later joined the push lane. `allowsPush` remains as the class gate and is
currently open for every event; a suppression that genuinely applied to *every* notification
transport would belong there.

The move also removes a live inconsistency: the same ntfy topic used to get a different event
set depending on whether it was configured as a webhook or through its own settings.

## `ServerEvent`

One vocabulary, client-facing and wire-constrained — **every case exists because a client
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

**Webhooks have no suppression flag at all** — every event reaches subscribed webhooks.

### Rate limiting coalesces; it does not drop

`new-findmy-location` carries `minimumInterval: 250 ms`. Two properties matter:

- **Coalescing, not dropping.** Keeping the first event in a window and discarding the rest is
  right for a counter and wrong for state: a FindMy batch covering forty devices would deliver one
  position and lose thirty-nine, and the survivors would be the *oldest*. Keyed per device, the
  newest position for each is delivered, spaced.
- **This one limit is global, not keyed.** Everywhere else the limiter keys per chat or device so
  a busy one cannot starve a quiet one. FindMy is deliberately different: the server is a single
  FindMy client as far as Apple is concerned, and keying per device would multiply the permitted
  rate by the number of devices — exactly the pressure the limit exists to avoid. It is the
  *rate* that is capped, not the freshness.

The 250 ms spacing is expressed as policy rather than a `sleep` in the emit loop. A sleep blocks
the whole handler, so a 40-device batch stalls processing for ten seconds.

---

## Sinks

```swift
public protocol EventSink: Sendable {
    func accepts(_ event: ServerEvent) -> Bool
    func deliver(_ event: ServerEvent) async
}
public protocol CustomEventSink: EventSink {}
```

**Every sink is independently optional, and there is no primary delivery route.** A socket-only
install, a webhook-only install and a full FCM install are all first-class, and none of them
should warn about the sinks it does not have.

| Sink | Enabled by | Notes |
|---|---|---|
| socket | always | The only route many desktop (Linux/Windows) clients use |
| push | a Firebase config being present | **Optional.** No config means the sink is simply not registered — not a degraded state |
| `WebhookSink` | any configured webhook | Per-webhook event subscription |
| `NtfyProvider` | a configured ntfy target | Maps the event onto ntfy's actual header protocol — title, body, priority, tags, click action, auth token, self-hosted server URL |

**Registration is the on-switch.** `EventBus.register(_:)` is what makes a sink active; an
unconfigured sink is *not registered*, never registered-and-disabled. That distinction is what
keeps "no Firebase" a valid deployment rather than a warning state.

Setup and health checks must have a **no-push-provider path**: a socket-only or webhook-only
install completes setup with no Firebase prompt and no warning banner.

### `emit` does not protect the caller

`EventBus.emit` returns once every sink has finished **or timed out** (30 s default). There is no
subscriber buffering and no backpressure valve.

**`emit` never waits for delivery.** Each sink has its own lane — a serial queue with a
per-event timeout — so the caller returns once the event is queued, order is kept per sink,
and a slow webhook delays only itself. Tests that need to observe delivery call
`bus.settle()`; shutdown calls `flushPending()`, which flushes the rate limiter and settles.
Delivery latency is a sink's problem, never the detector's.

Delivery failures are **logged, not raised**. One failed webhook POST is not worth interrupting
anyone over, and the sink itself raises once a failure becomes persistent — it is the only thing
that knows the difference.

---

## Payload codecs

Encoding is the final stage of delivery, behind a protocol, so **no event producer changes when
the codec changes**:

```swift
public protocol EventPayloadCodec: Sendable {
    var identifier: CodecIdentifier { get }
    var capabilities: PayloadCapabilities { get }
    func encode(_ event: ServerEvent, for device: DeviceIdentity?) async throws -> EncodedPayload
}
```

### `legacy-v1` — the default

Full serialized objects. Push gets `{type, data: <stringified JSON>}`; the socket gets the raw
object, never envelope-wrapped. **This is the default for every target and does not move.**

### `reference-v2` — identifiers only, client hydrates

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
  payload still learns **who you are talking to and when** — just not what was said. Say this
  plainly; "content never transits Google" is easy to hear as "nothing does".
- Mitigations: a configurable hint set (`.none` | `.senderOnly` | `.senderAndPreview`), and a
  batch `POST /api/v1/message/hydrate {guids: [...]}` so a burst of notifications costs one
  request.

### `sealed-v2` — full payload, end-to-end encrypted

Layered **on top of** the reference-v2 envelope rather than replacing it: routing metadata stays
plaintext, the body is sealed, and the two can mix. Hiding the metadata too is what this adds over
`reference-v2` — the whole body, chat GUID included, is inside the ciphertext and only the event
name stays visible.

- **X25519 key agreement + ChaCha20-Poly1305** via swift-crypto. The device generates a keypair at
  registration and submits its public key; **each message uses a fresh ephemeral server key**,
  giving per-message forward secrecy.
- Envelope: `{"v":2,"t":"new-message","alg":"x25519-chacha20poly1305","epk":"…","n":"…","ct":"…"}`.
- Devices registered without a public key transparently fall back to `reference-v2`.

### Negotiation is per-delivery-target, not a global flip

This is what makes an alternate codec deployable against a mixed fleet. It must not assume push
registration is where capability is declared — many installs have no push at all.

| Target | Declares capability via |
|---|---|
| Socket client | handshake query param `codecs=`, defaulting to `legacy-v1` |
| Paired device | `supportedCodecs` + `publicKey` at enrollment — works with or without push |
| Push device | optional `supportedCodecs` / `publicKey` on `POST /api/v1/fcm/device` |
| Webhook / ntfy target | a per-target column in its config row |

The server resolves `min(serverPreference, targetSupport)` at delivery time, so **one event can
produce a `legacy-v1` socket frame, a `sealed-v2` push payload and a `legacy-v1` webhook POST in
the same fan-out**. `event_payload_codec` is the server's *preference ceiling* and defaults to
`legacy-v1`. `GET /api/v1/server/info` advertises `supported_payload_codecs` and `payload_codec`.

Webhook and ntfy targets keep a per-target setting deliberately: a self-hosted consumer on the
same LAN has entirely different trust properties from Google's push infrastructure, so it can stay
on `legacy-v1` while push moves to `sealed-v2`.

`reference-v2`'s round-trip cost is also asymmetric — a desktop client on an open socket hydrates
instantly, while an Android device woken by a data-only push pays real latency and
background-execution cost. Per-target selection lets each pick what suits it.

**Both alternates are default-off and stay that way** until clients can decrypt or hydrate. See
[`../.claude/docs/decisions.md`](../.claude/docs/decisions.md).

---

## Socket delivery

`Sources/BBSocketIO` is a native Engine.IO / Socket.IO implementation, sharing the same NIO HTTP
server as the REST API.

**Must be exact:**

- Engine.IO handshake over **both** polling and websocket, with **EIO3 and EIO4** — the
  equivalent of `allowEIO3: true` is load-bearing for older Flutter clients.
- Transport upgrade (polling → websocket), `pingInterval: 60000`, `pingTimeout: 120000`,
  `upgradeTimeout: 30000`, `maxHttpBufferSize: 100MB`.
- Handshake auth: `password` ?? `guid` from the query, decoded **exactly once**, constant-time
  compared; failure → **silent disconnect with no error event**.
- Packet encoding for `EVENT` (type 2) and `BINARY_EVENT`, default namespace `/`.
- Broadcast payloads under `legacy-v1` are the **raw object**, never envelope-wrapped.

Socket response envelopes still emit `encrypted: false` even though the old `encrypt_coms` AES
path is gone, because client parsers read the field.

### Replay is strictly opt-in

The server maintains a monotonic sequence and a bounded in-memory ring of recent events
(size-capped, minutes not hours).

Adding a `seq` field to broadcast payloads would alter every event body, so **it is not added by
default.** A client opts in with `replay=1` in the handshake, and only then receives `seq` and
gains `?since=<seq>` reconnection; overflow or an unknown `seq` yields a `resync-required` marker
so it falls back to a full fetch. **For every client that does not ask, broadcast payloads are
byte-identical** — the ring is maintained and never consulted.

### Inbound commands

Clients drive the server over HTTP; the socket is server→client events only. An unrecognised
inbound event is **ignored rather than answered**.

If the ~33 legacy inbound commands are ever needed, they adapt over the same interfaces the HTTP
handlers use — no business logic is duplicated. Quirks to preserve if so: `get-vcf` and
`check-for-server-update` both ack on channel **`save-vcf`**; `attachment-chunk` is never
encrypted; the presence of a client ack callback changes delivery from channel-emit to callback.

---

## Extending delivery

`CustomEventSink` is the extension point. `WebhookSink` is written against it
rather than being special-cased, which is what keeps the surface honest — if it cannot express the
built-ins, it is not good enough.

A new delivery route is a new sink: conform, declare a `SinkID` **and a `SinkRouting`**, and
register it. Registration is the on-switch, so a sink with no configuration is simply never
registered.

`SinkRouting` — `.socket`, `.push` or `.webhook` — is which suppression rules the sink obeys,
and it deliberately has no default. The bus used to infer it by switching on `SinkID`, which
is a string wrapper, so the switch needed a `default` and every sink outside the four known
constants silently inherited webhook routing. Saying which class you are in is one line;
inheriting the wrong one is invisible.
