# FaceTime — what the dumped headers give us

Analysis of the FaceTime classes in `macos-26.5.2/` (all in `TelephonyUtilities.framework`),
read from the runtime. The goal is to establish which of the flows below are reachable, what
each step actually calls, and where the gaps and risks are — **not** to build it yet.

## The three flows, mapped to real calls

**Flow A — link handoff (the robust one).**
1. Mac generates a FaceTime link → `TUConversationManagerXPCClient generateLinkWithInvitedMemberHandles:linkLifetimeScope:completionHandler:` → returns a `TUConversationLink` whose `URL` is the shareable link.
2. Server hands the URL to the client.
3. Client opens it on their own device and joins as a participant. The Mac was never in a call — it only *minted* the link — so there is nothing for it to drop.
4. Client forwards the link to a friend; the friend joins the same way. Nothing on the Mac is involved.

**Flow B — Mac calls the person, then bows out.**
1. Mac dials → `TUCallCenter dialWithRequest:completionWithError:` with a `TUDialRequest` (`handle`/`handles`, `video` = true, `service` = FaceTime). This creates a real call the Mac is *in*.
2. Mac generates a link for that live call → `generateLinkForConversation:completionHandler:` (the conversation comes from `TUCallCenter activeConversationForCall:`).
3. Server returns the link to the client; client joins.
4. Mac leaves → `TUConversationManagerXPCClient leaveConversationWithUUID:` (the conversation's `groupUUID`) or `TUCallCenter disconnectCall:`.

Flow A is strictly simpler and safer: the Mac never joins media, so "drop when the client joins" is a non-problem. Flow B exists for one reason the product actually wants — **the Mac should place a real call so the other person's device rings**, instead of the client having to send a link out-of-band. That is a genuine capability difference, not a nicety, so B is in scope even though A is the safer default.

**Flow C — incoming call, answered by a client.**
1. Someone FaceTimes the Mac. The helper observes the incoming call and forwards it to clients (caller handle, display name, call UUID).
2. A client "picks up" via an API call.
3. The Mac answers → `TUCallCenter answerCall:` / `answerOrJoinCall:`, then mints a link for the now-active conversation → `activeConversationForCall:` + `generateLinkForConversation:completionHandler:`.
4. The link is sent back to the client, which joins from its own device.
5. Once the client has joined, the Mac drops — leaving the caller talking to the client.

Flow C is the most delicate of the three, because a **remote party is already connected** and holding. If the Mac drops before the client has actually joined, a 1:1 call collapses and the caller is hung up on. So C shares Flow B's drop-timing problem *and* raises the stakes: the drop must be gated on a confirmed client-join event, never on a timer. The membership-diff delegate callback (below) is what makes that safe; without it, C should not ship.

## Every primitive, and where it is

Confirmed present on macOS 26.5.2 unless noted. Verify each with a selector test before
calling — the drift below is exactly why.

### Links — `TUConversationManagerXPCClient`
| Operation | Selector |
|---|---|
| Create a link | `generateLinkWithInvitedMemberHandles:linkLifetimeScope:completionHandler:` |
| Create a link for a live call | `generateLinkForConversation:completionHandler:` |
| Pre-invite specific people | `addInvitedMemberHandles:toConversationLink:completionHandler:` |
| Name the link | `setLinkName:forConversationLink:completionHandler:` |
| List active links | `getActiveLinksWithCreatedOnly:completionHandler:` |
| Check a link is still valid | `checkLinkValidity:completionHandler:` |
| Invalidate a link | `invalidateLink:deleteReason:completionHandler:` |
| Renew expiry | `renewLink:expirationDate:reason:completionHandler:` |

A `TUConversationManager` (non-XPC) exposes `activatedConversationLinks`,
`activeConversations`, and `generateLink…` too — the ObjC helper uses the plain manager for
reads and the XPC client for mutations.

### Membership / the "let me in" gate — `TUConversationManagerXPCClient` + `TUConversation`
| Operation | Selector |
|---|---|
| Admit a knocking participant | `approvePendingMember:forConversation:` |
| Reject one | `rejectPendingMember:forConversation:` |
| Remove a joined member | `kickMember:conversation:` |
| Read who is waiting | `TUConversation.pendingMembers` (set of `TUConversationMember`) |
| Read who is in | `TUConversation.remoteMembers`, `.localMember` |

`TUConversationMember` carries `handle` (a `TUHandle`), `nickname`, `joinedFromLetMeIn`, and
the `dateInitiatedLetMeIn` / `dateReceivedLetMeIn` timestamps — enough to attribute a knock to
a specific address and decide whether to auto-admit.

### Incoming call — `TUCallCenter` + `TUCall` (Flow C)
| Operation | Selector / property |
|---|---|
| The current incoming call | `TUCallCenter.incomingCall`, `.incomingVideoCall`, `.incomingCalls`, `resolvedIncomingCall` |
| Is this call inbound | `TUCall.isIncoming` |
| Who is calling | `TUCall.handle` (`TUHandle.value`), `.displayName`, `.callerNameFromNetwork` |
| Answer it | `answerCall:` / `answerOrJoinCall:` / `answerWithRequest:` |
| Link for the answered call | `activeConversationForCall:` → `generateLinkForConversation:completionHandler:` |

Detection rides the same status-change notification as everything else
(`TUCallCenterCallStatusChangedNotification`), filtered by `isIncoming`. `callerIDBlocked` is
worth surfacing so a client can distinguish "unknown caller" from "we failed to resolve them."

### Outbound call — `TUCallCenter` + `TUDialRequest` (Flow B only)
| Operation | Selector |
|---|---|
| Dial | `dialWithRequest:completionWithError:` (or `dialWithRequest:`) |
| Answer an incoming call | `answerCall:` / `answerOrJoinCall:` |
| Join by request | `joinConversationWithRequest:` (takes a `TUJoinConversationRequest`) |
| Leave / drop | `disconnectCall:` / `disconnectCall:withReason:` / `leaveConversationWithUUID:` |
| Find a call | `callWithCallUUID:` |
| The live conversation for a call | `activeConversationForCall:` |
| Enumerate calls | `currentCalls`, `incomingCalls`, `incomingCall`, `_allCallsWithStatus:` |

`TUDialRequest` is built from a `handle`/`handles` set plus `video` and `service`; a `TUHandle`
comes from `handleWithDestinationID:` or the normalized constructors
(`normalizedPhoneNumberHandleForValue:isoCountryCode:`, `normalizedEmailAddressHandleForValue:`).

### Call/status reads — `TUCall`
`callStatus` (int), `callUUID`, `handle`, `conversationGroupUUID`, `isSendingAudio`,
`isSendingVideo`, `endedReasonString`. The ObjC helper treats `callStatus == 4` as
"waiting to be answered" and `callStatus == 1` as "waiting to be left"; those magic numbers
are the shipping helper's and should be pinned by a selector/behaviour test, not trusted
blind.

## Why the ObjC helper "almost never works" — and where the real problem is

The existing FaceTime helper is a **loose** reference: it tells you which classes and
selectors exist, and nothing about whether calling them works. In the field it is reported as
broken far more often than not, and the dumped headers make the likely reasons concrete. The
selectors are not the hard part — the **client lifecycle** is.

**1. It uses a cold, throwaway XPC client.** `TUConversationManagerXPCClient` has **no
`sharedInstance`**. It is a stateful client that must be *registered* and have its *initial
state fetched* before any of its data is real — the header spells this out:
`registerWithCompletionHandler:`, `fetchInitialStateWithCompletionHandler:`,
`_requestInitialStateIfNecessary`, `hasInitialState`, `hasRequestedInitialState`, plus a live
`xpcConnection` and a `delegate`.

The ObjC helper instead does `[[TUConversationManagerXPCClient alloc] init]` **fresh, inline,
on every dispatch**, reads `activeConversations` / `activatedConversationLinks` immediately,
and lets the object deallocate at the end of the call. On a client that was never registered
and never synced initial state, those collections are **empty** — so `admit-pending-member`
iterates nothing and silently succeeds-at-nothing, and `get-active-links` returns an empty
list. And because the object is released as soon as the async call is kicked off, the XPC
round-trip's completion block for `generate-link` can be torn down before it ever fires, so no
URL comes back. Both failure shapes match "it doesn't work" exactly.

**2. There is no live-update path, so "wait for join, then drop" has nothing to wait on.** The
helper's pending-member swizzle (`receivedTrackedPendingMember:forConversationLink:`) is
**commented out** — it was never finished. Without it, the Mac has no signal that the client
joined, which is the pivot of both of your flows.

**When to (re)connect the client** is not a guess either: `TelephonyUtilities` posts
`CSDConversationManagerClientsShouldConnectNotification` (and sibling
`…ProviderManagerClientsShouldConnectNotification`) — the daemon's signal that clients should
establish or re-establish their connection. A long-lived client observes it and re-registers,
which is how it survives the daemon cycling without going silently stale. The throwaway-client
approach never sees this because it is constructed and destroyed inside a single request.

**Both problems have the same fix, and it is the real design of this feature:** hold ONE
long-lived `TUConversationManagerXPCClient` for the helper's lifetime, `register` it, fetch
initial state once, set its `delegate`, re-register on the connect notification above, and
drive everything through that instance. The delegate protocol
`TUConversationManagerDataSourceDelegate` (dumped alongside) is exactly the event path:

- `conversationsChangedForDataSource:updatedIncomingPendingConversationsByGroupUUID:` — someone
  is knocking. This is the clean, no-swizzle replacement for the abandoned swizzle, and the
  trigger for auto-admit.
- `conversationsChangedForDataSource:conversationsByGroupUUID:oldConversationsByGroupUUID:` —
  membership changed: the diff old→new is how you detect "the client joined," which is the
  cue for the Mac to drop.
- `receivedTrackedPendingMember:forConversationLink:` — per-member let-me-in tracking.

So the reconnaissance conclusion is the opposite of "port the helper": the helper's structure
is the bug. A working version is a small state machine around one registered client plus its
delegate — not a set of one-shot selector calls.

## Call-status events (Flow B)

For the outbound-call flow, `TUCallCenter` *does* have a proper `sharedInstance`, and call
status is observable by notification — `TUCallCenterCallStatusChangedNotification` /
`TUCallCenterVideoCallStatusChangedNotification`, which the ObjC helper already listens to for
`ft-call-status-changed`. That half is more likely to work than the conversation-manager half,
because it is not built on a throwaway client.

## The injection target must be kept alive — and that is not free

The helper injects into **`com.apple.FaceTime`** (FaceTime.app), which is the *right* target:
that process is legitimately registered with the call daemons, so being inside it is what gives
`TUCallCenter`/the conversation manager a real backing connection. Injection is mechanically
identical to Messages — `/System/Applications/FaceTime.app`, hardened runtime, on the sealed
system volume; SIP-off + library-validation, no AMFI-off. Injecting it does imply it is alive
*at inject time*. It does **not** imply it stays alive, and two facts (checked, not assumed)
make that the crux:

1. **`FaceTime.app` declares `NSSupportsAutomaticTermination = true`** (Info.plist, macOS
   26.5.2). macOS may terminate it when it is idle and windowless — taking the helper with it.
   Messages declares the same flag, but the Messages helper survives because BlueBubbles keeps
   Messages running anyway (it needs it for iMessage) and supervises it. FaceTime is an *extra*
   app the server does not otherwise need, so keeping it resident is a new, ongoing cost — and
   likely needs an explicit activity assertion to block automatic termination, not just a
   relaunch-on-exit loop.

2. **Incoming calls are launched by the daemon, un-injected.** An incoming FaceTime is
   delivered by the call daemon, which launches FaceTime.app itself — a normal launch, no
   `DYLD_INSERT_LIBRARIES`, so the helper is **not** in that instance. Relying on "the call
   opens FaceTime" yields a FaceTime with no helper, and the event is missed. Flow C therefore
   requires a *pre-existing*, supervised, injected instance to already be running so the daemon
   reuses it (only one FaceTime.app runs at a time). In practice: catching incoming calls means
   an always-on injected FaceTime.app.

So the injection target answers the entitlement and daemon-registration question — it is why
`TUCallCenter sharedInstance` is real there — but it turns the reliability problem into a
lifecycle problem: supervise an injected FaceTime.app, hold it against automatic termination,
and never depend on the daemon's own launch. That plus the long-lived registered
conversation-manager client is the durable design.

## Drift already found (why the runtime dump matters)

The ObjC helper's ktool headers (iOS 16 SDK) disagree with macOS 26.5.2:

| ObjC helper header | macOS 26.5.2 |
|---|---|
| `TUConversationJoinRequest` | **renamed** → `TUJoinConversationRequest` |
| `CSDConversation`, `CSDConversationManager` | **gone** |
| `invalidateLink:completionHandler:` | now `invalidateLink:deleteReason:completionHandler:` |

Anything ported from those headers by name will silently no-op on the current selector-guarded
path. The `CSD*` classes appear only in the helper's commented-out swizzles, so nothing live
depends on them — but a port must not reintroduce them.

## What already exists in this project

- **Node server** ships this surface — `PrivateApiFaceTime` has `generate-link`,
  `admit-pending-member`, `answer-call`, `leave-call`; `facetimeInterface` wraps
  create/answer/leave. It is a reference for the **wire format** and the intended shape, NOT a
  reference for working behaviour: it drives the same unreliable ObjC helper, so it inherits
  the reliability problem above. Match its request/response shape; do not assume its flow
  works end to end.
- **Swift server** currently has three FaceTime routes (`facetime/session`, `answer/:call_uuid`,
  `leave/:call_uuid`) whose handlers report "not yet implemented" at startup, plus
  `checkFaceTimeAvailability` (done) and the `faceTimeCallStatusChanged` event (decoder exists).
  The contract has no link-generation or admit-member method yet.
- **Feature flagging** is in place (`BBSettings/FeatureFlags.swift`) — a FaceTime-link feature
  would gate the same way FindMy does, and probably should, since it initiates calls.

## Pre-inviting a member does NOT ring them — MEASURED

`generateLinkWithInvitedMemberHandles:linkLifetimeScope:completionHandler:` accepts handles
and the daemon takes them without error, but the invited party receives **nothing**: no ring,
no push, no notification. Tested on macOS 26.5.2 against two real accounts; the link appeared
only in the LOCAL Mac's FaceTime recents, because the Mac created it.

So the invited-member set is **access control, not an invitation**: it constrains who may join
a link, it does not tell anyone the link exists. That is worth keeping for a "only these people
can join" restriction, but it is not a way to reach someone.

The consequence for the flows: **there is no way to make a recipient's device ring without the
Mac placing the call.** Ringing *is* being the caller. Flow B's join-then-leave is therefore
required, not an implementation detail that a cleverer API call could avoid — which is why the
auto-drop (poll membership, leave only once a real participant has joined) is load-bearing
rather than a convenience.

Do not re-derive this by re-reading the headers: the selector's existence and its silent
success both suggest it should work, and neither is evidence that it notifies anyone.

## Flow B works — and the drop threshold is THREE, not two

Verified on a live call, macOS 26.5.2: the Mac dialled a real address, the recipient's device
**rang**, and they **answered**. Flow B is real.

Three `TUDialRequest` bugs had to be fixed first, each named by TelephonyUtilities' own
`validityErrors` (read them — they are far better than the opaque `TUDialRequestErrorDomain`
code the dial returns):

1. **`-[TUDialRequest init]` is refused outright** — "call designated initializer instead".
2. **`initWithService:` with a guessed integer is wrong.** It yields a request with no
   provider → Code=6 "Requested video for a provider which doesn't support it" and Code=8
   "Provider does not support the specified handle type". Use `initWithProvider:` with
   `TUCallProviderManager.faceTimeProvider`, reached from `TUCallCenter.providerManager`
   (the manager has no singleton, but the call center holds the live one). Confirmed
   resolving to `com.apple.telephonyutilities.callservicesd.FaceTimeProvider`, whose
   `supportedHandleTypes=3,2` includes email (3).
3. **Handles must be set AFTER `initWithProvider:`.** The initializer builds a fresh request
   and discards anything set on the allocation → `handles=(null)` and Code=7 "destinationID
   and contactIdentifier are both nil/empty".

Also: **`-[TUHandle description]` REDACTS the address**, printing an opaque `u:…` token. A
handle that looks mangled in a log is almost certainly fine — read the `value` property.
This cost a full debugging detour; do not chase it again.

### The drop threshold — the bug that hangs up on a real person

A FaceTime call does not survive dropping below two participants. On a 1:1 call those two are
the Mac and the callee, so a condition like "leave once a real participant has joined" is
satisfied **the moment the callee answers** — and leaving then collapses the call on them.

The Mac may only leave once there are **three**: Mac + callee + client. `remoteMembers`
excludes the local participant, so the threshold is **two joined remotes**
(`remotesRequiredBeforeLeaving`). Pending (knocking) members do not count — they are not
holding the call open.

Two related rules, both learned the same way:

- **Arm the watcher on the DIAL, not on the link.** The Mac is a live participant the instant
  the dial returns. Arming cleanup only after a successful `generateLinkForConversation:`
  meant a link failure stranded the Mac in a live call — observed: the callee answered and the
  Mac never left. The watcher is now armed off the call, and a link failure reports the live
  call rather than hiding it.
- **On timeout, the Mac STAYS.** Leaving would hang up on whoever answered. An idle extra
  participant is a nuisance a human can end; severing a live call between two real people is
  not. `POST facetime/leave` is the explicit escape hatch.

### The conversation is not ready when the dial returns

`generateLinkForConversation:` returned no link for a freshly-dialled call: at the instant
`dialWithRequest:` returns, the call has no active conversation yet. `generateLink(forCall:)`
now POLLS `activeConversationForCall:` (500ms, up to 15s) and distinguishes "no such call"
from "call exists but never became a conversation", instead of failing blind.

### The Mac is muted and camera-off while it holds the call

During a hand-off the Mac is a genuine participant — the other party would see its camera and
hear its microphone until the client joins. `TUCall setMuted:` / `setIsSendingVideo:` are
applied the moment a call is dialled or answered, so the Mac is a silent placeholder. It is
still a VIDEO call; only the Mac's uplink is silenced, and the joining client sends its own
camera normally.

### Join order does not matter

If the client joins BEFORE the callee answers, the Mac must not leave — one remote is not
enough to keep the call alive, and the Mac is the calling party holding the outgoing
invitation open. The `joined >= 2` half of the drop condition covers this: the Mac waits, the
callee keeps ringing normally, and the hand-off completes when they answer.

## Gating — ship all three, select at runtime, not by comment-out

The ask is "implement both/all flows and enable whatever works best." The right vehicle is the
**feature-flag + settings system already in the tree** (`BBSettings/FeatureFlags.swift`,
proven by the FindMy work), not `#if` blocks or commented-out code. Runtime gating beats
commenting-out on every axis that matters here: the flows can be flipped on a real Mac without
a rebuild (which is the only place they can be tested), a flow that regresses on a new macOS
can be turned off in the field, and dead code does not rot behind a comment.

Proposed shape (names illustrative):

- **`feature_facetime_enhanced`** — master flag, off by default, mounts the new FaceTime
  routes. Same pattern as `feature_findmy_enhanced`. Nothing below is reachable without it.
- **`facetime_outgoing_mode`** — an enum setting choosing the *outbound* strategy, because A
  and B are two answers to the same question ("client wants to start a call"):
  - `link-only` (Flow A) — default. Mint a link, hand it back. Never places a call.
  - `call-then-link` (Flow B) — dial the person, mint a link, hand it back, drop when the
    client joins.
  A client asks to start a call the same way; the server picks the mechanism from config. If
  B proves flaky in the field, one setting change falls back to A with no code change.
- **`feature_facetime_incoming`** — separate flag for Flow C (capture incoming → forward →
  client answers → link back → drop). Kept separate because it is the most fragile and the
  most stateful: it should be possible to run outbound without it. **Guarded additionally by a
  hard precondition in code:** C refuses to arm unless the membership-diff join event is
  actually being delivered, because its drop step is unsafe without it.

Both A and B live as real, compiled code paths selected by `facetime_outgoing_mode`; that is
the "implement both, gate by what works" the ask wants, expressed as configuration rather than
as a comment someone has to remember to toggle.

## Assessment

Flow A (mint a link, hand it off, admit knockers) is the clean design — the Mac never joins
media, so there is no drop to time — and every mutation it needs is a confirmed present
selector. But **"the selectors exist" is not "the ObjC helper's approach works," and it
demonstrably does not.** The value in a rewrite is not porting the helper; it is fixing the
lifecycle the helper got wrong: one long-lived, registered, initial-state-synced
`TUConversationManagerXPCClient` with a delegate, instead of a throwaway client per call. Get
that right and Flow A becomes a small, testable state machine; get it wrong the same way and a
Swift rewrite will "almost never work" for the same reasons.

Flow B (Mac dials, then drops) adds a live call and its teardown on top, and inherits
FaceTime's answer/join/disconnect state machine — more surface, version-fragile `callStatus`
constants, and a genuine drop-timing problem. Worth it only if ringing the callee from the Mac
is a hard requirement rather than a nicety. The call side at least rests on a real
`sharedInstance`, so it starts from firmer ground than the conversation-manager side.

Flow C is worth building and the primitives are all present, but it is the highest-risk of the
three and must be gated on a real join event — never a timer — or it hangs up on the caller.
It is correctly a separate flag.

Recommended order if this gets built:
1. **Verify the reliability hypotheses first, on a real Mac** — that a *registered,
   state-synced* client returns real `activeConversations`/links where the throwaway one
   returns empty; that observing `CSDConversationManagerClientsShouldConnectNotification` and
   re-registering keeps it live; and that FaceTime.app being alive is a precondition. These are
   the actual reasons the current helper fails. Confirm them before writing feature code, or a
   Swift rewrite reproduces the same "almost never works."
2. Build the long-lived client + `TUConversationManagerDataSourceDelegate` event path — the
   shared foundation all three flows sit on.
3. Contract + server scaffolding (types, wire format matching Node, routes, flags). This part
   is testable without a Mac, the same way the FindMy contract/client/route tests are.
4. Flow A behind `feature_facetime_enhanced` (`facetime_outgoing_mode = link-only`).
5. Flow B as the second `facetime_outgoing_mode`.
6. Flow C behind `feature_facetime_incoming`, only after the join event from (2) is proven.

## Implementation status (what is built, what needs a Mac)

Built and server-tested (1106 tests green):

- **Contract** — `FaceTime.swift`: statuses (raw values corrected from Node), link, call,
  member, request/result types; protocol methods; two typed events (`faceTimeCallChanged`,
  `faceTimeMembershipChanged`).
- **Server client** — `PrivateAPIClient` FaceTime methods + wire encode/decode, with tests.
- **Helper bridge** — `FaceTimeBridge.swift`: the long-lived registered
  `TUConversationManagerXPCClient` (register → fetch initial state → delegate → re-register on
  the daemon's connect notification), `TUCallCenter` calls, membership reads. Selector-guarded;
  every selector it calls is pinned by `IMCoreSelectorTests` against the live runtime.
- **Host guard** — the bridge refuses to touch TelephonyUtilities unless it is running inside
  `com.apple.FaceTime`. This is load-bearing: constructing the XPC client in any other process
  traps and takes the host down (found by a test that crashed before the guard existed).
- **Flags + settings** — `feature_facetime_enhanced`, `feature_facetime_incoming`,
  `facetime_outgoing_mode` (link-only / call-then-link).
- **Routes + handlers** — the three inherited routes (`session`/`answer`/`leave`) implemented
  and gated; additive `link` / `call` / `admit` / `members` / `handoff`. Flow C's drop is a
  bounded poll of typed membership (admit knockers, wait for a real join, then leave), not a
  timer and not the notification-database hack.

NOT yet built — needs your Mac and, in one case, a quieter tree:

1. **Per-process request routing in the transport.** FaceTime actions must go to the
   FaceTime-injected helper, not whichever helper registered last. `SocketTransport.write`
   currently targets the most-recent client; it needs an optional target by bundle id, and
   `PrivateAPIClient` needs to pass `com.apple.FaceTime` for FaceTime actions. Until this
   lands, a running Messages helper and FaceTime helper on one socket can misroute.
2. **Injecting into and supervising FaceTime.app.** `DylibInjector` targets Messages today.
   FaceTime needs the same injection plus lifecycle supervision — kept alive against
   `NSSupportsAutomaticTermination`, relaunched-with-injection on exit — so an incoming call
   reaches an already-injected instance rather than the daemon's own un-injected launch.
3. **On-device validation of the reliability hypothesis.** The whole design rests on "a
   registered, state-synced client returns real conversations/links where the throwaway one
   returns empty." That is argued from the headers and cannot be proven under `swift test`.
   Confirm it on a SIP-off Mac before trusting the flows.

The reconnaissance finding held up in code: the existing implementation's structure is the
defect, and the shared fix — one registered, delegate-driven client, host-guarded — is the
foundation all three flows now sit on. The remaining work is transport routing, injection, and
proving the hypothesis on real hardware.

## Call history — the recents API

`TUCallCenter` exposes the calls happening **now** and keeps no history; there is no
"recent calls" selector on it. The log lives in a Core Data store that both FaceTime and
Phone write:

```
~/Library/Application Support/CallHistoryDB/CallHistory.storedata
```

Reading it directly is why `GET facetime/recents` is the one FaceTime route that needs **no
helper injection and no SIP changes**. It needs Full Disk Access, which the server already
has for `chat.db`.

### `ZCALLRECORD` columns that matter

| Column | Meaning |
| --- | --- |
| `ZDATE` | Seconds since **2001-01-01** (Core Data epoch). Add `978307200` for Unix time. |
| `ZCALLTYPE` | `8` = FaceTime video, `16` = FaceTime audio, `1` = carrier call. |
| `ZORIGINATED` | `1` = outgoing, `0` = incoming. |
| `ZANSWERED` | `1` = answered. |
| `ZSERVICE_PROVIDER` | `com.apple.FaceTime`, or a carrier identifier for phone calls. |
| `ZUNIQUE_ID` | FaceTime's own call UUID — the same value `TUCall.callUUID` reports. |
| `ZPARTICIPANTGROUPUUID` | Raw **16-byte blob**, not text. The conversation's group UUID. |
| `ZDURATION` | Float seconds. |

There is no "missed" column. Missed is derived: incoming **and** unanswered. An unanswered
*outgoing* call is not a missed call, and treating `ZANSWERED = 0` as missed would badge
every call you placed that nobody picked up.

### The join table name is not a constant

Participants live in a many-to-many table Core Data names after internal **entity numbers**:

```
Z_2REMOTEPARTICIPANTHANDLES
  Z_2REMOTEPARTICIPANTCALLS   -> ZCALLRECORD.Z_PK
  Z_4REMOTEPARTICIPANTHANDLES -> ZHANDLE.Z_PK
```

Those digits are assigned by the model compiler and shift when Apple adds an entity, so
hardcoding `Z_2…` would silently return **zero participants** on another macOS build rather
than failing loudly. `CallHistoryRepository` discovers the table and both column names at
runtime by shape (`Z_*REMOTEPARTICIPANTHANDLES`, then the columns ending `CALLS` / `HANDLES`).

A 1:1 call may have no join rows at all, in which case the record's own `ZADDRESS` is the
participant list — otherwise the call reads as having nobody on it.

### Cross-check: the `temp:` guest handle

Recents independently confirms what the live tests showed. A browser guest joining by link is
recorded as a participant with a throwaway handle:

```json
"participants": [
  { "address": "temp:ec3f5ec6-d15a-4f04-840d-eb067bab483f" },
  { "address": "<invited address>" }
]
```

A link guest has **no FaceTime address**. That is why `FaceTimeMember.isLightweight` — not a
head count — is what identifies the requesting client during the Flow B hand-off.

### Wire naming

The database's vocabulary is not the API's. `GET facetime/recents` maps it to the shape the
other `facetime/*` responses already use — snake_case, millisecond times, handle objects:

| Wire field | Source | Why not the raw name |
| --- | --- | --- |
| `call_uuid` | `ZUNIQUE_ID` | It IS the call UUID (`TUCall.callUUID`), and `callObject` already spells it `call_uuid` — so a recents entry correlates with a live call a client holds. |
| `date_created` | `ZDATE` | Milliseconds since the Unix epoch, like every other date the API returns. The column is seconds since 2001. |
| `duration` | `ZDURATION` | Milliseconds, so `date_created + duration` is meaningful. The column is float seconds. |
| `service` | `ZSERVICE_PROVIDER` | Elsewhere `service` is a name a client shows ("iMessage", "SMS"), so the bundle id becomes `"FaceTime"` / `"Phone"`. An unrecognised provider passes through verbatim rather than being flattened into the wrong label. |
| `participants` | join table | Handle **objects** (`{"address": …}`), matching `chat.participants`, so a client needs no second code path for bare strings. |
| `is_missed` | *derived* | There is no missed column. Incoming **and** unanswered. |

Fields with no database counterpart are absent rather than null — `display_name` and
`group_uuid` are omitted when macOS stored none.

## One socket per app — the sandbox forces it

The helper transport originally bound **one** Unix socket, inside Messages' container, and
routed by the registering process id. That could never work once a second helper existed.

A sandboxed app can only reach a socket inside its **own** container, and the rule is
symmetric. Measured with both helpers injected, binding one path at a time:

| Socket location | Connects | Cannot connect |
| --- | --- | --- |
| `~/Library/Containers/com.apple.MobileSMS/Data` | Messages | FaceTime — never appears |
| `~/Library/Containers/com.apple.FaceTime/Data` | FaceTime | Messages — registers, then drops |

The symptom was misleading. Whichever app did not own the container was silently absent, so
every **untargeted** action — sending, reactions, availability, focus status; everything that
does not name a process — fell through to "most recently connected" and was answered by the
wrong helper with `unknown action`. It looked like a missing action, not a missing helper.

The server now binds **one socket per app** and each helper connects to the one inside its own
container. Binding is best-effort per path: a Mac where FaceTime has no container yet still
gets a working Messages helper.

Untargeted requests also prefer the Messages helper explicitly rather than the most recent
connection, since every inherited action belongs to it.

## Dialling an address that is not FaceTime-capable

`dialFaceTime` **succeeds** on an address that cannot receive FaceTime calls: a `TUCall` is
created and reports `outgoing`. FaceTime.app puts up an alert —

> "…" in the contact card is not available for FaceTime

— no conversation is ever created, and the link poll times out. The API reported "the call was
placed, but FaceTime returned no join link" for a call that never had a chance to connect.

`POST facetime/call` now pre-flights every address through `check-facetime-availability` and
refuses with a 400 before any call object exists, so the alert never appears. An address the
check cannot verify is allowed through: the check runs via the Messages helper, and refusing
every call when it is unavailable would be worse than the error it prevents.

`POST facetime/dismiss-alert` clears a blocking alert if one does appear, and
`GET facetime/windows` reports what FaceTime.app is showing. Dismissal **cancels** rather than
confirms: the alert's other buttons offer to call a *different* address on the contact card,
and confirming could place a call nobody asked for.

## Invalidating links, and why it sometimes finds nothing

`invalidateLink:deleteReason:completionHandler:` needs the **`TUConversationLink` object**, not
its URL, so invalidation can only act on links it can enumerate. Two sources exist, and on
macOS 26.5.2 only one works:

| Source | Result |
| --- | --- |
| `getActiveLinksWithCreatedOnly:completionHandler:` | **nil** — populated through the data-source delegate, which is not installed (it crashes FaceTime.app) |
| `activatedConversationLinks` | the real link objects — **but only as of process start** |

`activatedConversationLinks` is not refreshed while FaceTime.app runs, for the same reason:
without the delegate nothing pushes updates into the client. So a link minted **now** is not in
the list until FaceTime restarts, and `DELETE facetime/link` reports nothing to do.

Measured: 24 links accumulated across a testing session, all invisible to invalidation. After
`POST facetime/restart`, the same request invalidated all 24.

**Workaround:** restart FaceTime, then invalidate. `POST facetime/restart` does this with the
helper re-injected.

This is also why the failure path must never report an empty success. It used to return
`{"count": 0}` whether it had found no links or had failed to invalidate every one it found —
indistinguishable outcomes, so a failed cleanup looked like a completed one. A link that cannot
be invalidated now reports why.

## Node compatibility of the inherited routes

`session`, `answer/:call_uuid` and `leave/:call_uuid` are the Node server's own FaceTime API and
must not change shape. Node answers:

```ts
new Success(ctx, { data: { link } })   // link is a bare URL STRING
new NoData(ctx, {})                    // 201
```

So `data.link` is the contract for `session` and `answer`, and `leave` answers **201**. The
rewrite returned `data.url` instead, and a client reading `data.link` got `undefined` on the two
FaceTime routes that had already shipped. `data.link` is now always present; `url` and
`group_uuid` ride along, since extra keys are harmless and the group UUID is what a client needs
to admit joiners.

Worth recording for context: **Node has no outgoing-call API at all.** Its `session` route mints
a bare link and then runs `admitAndLeave()` — `admitSelf()`, a fixed `waitMs(15000)`, then
`leaveCall()`. A stopwatch, with no check that anyone is still in the call, which is the likely
reason users reported it never worked. `POST facetime/call` is new, and waits for an active
outsider plus two remotes before the Mac leaves.

## Diagnostics are development-only

Three helper capabilities exist for debugging and are **compiled out of a release build**:

| Action | What it does | Why it is not exposed |
| --- | --- | --- |
| `facetime-debug` | dumps raw `TUConversation` / member / participant state | hands conversation internals to anyone with a read scope |
| `facetime-windows` | reports what FaceTime.app is showing | reveals UI state of another app |
| `facetime-dismiss-alert` | cancels a blocking modal | drives another app's UI; recovery, not a client action |

They are routed **only under `#if DEBUG`** — `AdditiveRoutes.debugDiagnostics` and
`FaceTimeHandlers.registerDebugDiagnostics`. `#if DEBUG` rather than a setting or an
environment variable on purpose: those are runtime switches, and a runtime switch can be
flipped on a production server, including by whoever holds an admin token. The guarantee wanted
here is "not in the binary", not "off by default".

Verified against the built products — the handler ids and their route paths appear in the debug
binary and not in the release one:

```
                          release  debug
facetime.debug                  0      1
facetime.windows                0      1
facetime.dismissAlert           0      1
:group_uuid/debug               0      1
dismiss-alert                   0      1
```

They are also covered by `FaceTimeRoundTripTests`, which drives the real dispatch over a real
socket with no HTTP involved, so they stay tested whether or not they are routed.
`RouteRegistrationTests` asserts both halves: present in a development build, absent otherwise.

Alert dismissal still happens automatically: `FaceTimeCleanup` cancels a blocking alert before
it does anything else, since an app stuck behind a modal cannot be driven. It **cancels** — the
alert's other buttons offer to call a different address on the contact card, and confirming
could place a call nobody asked for.
