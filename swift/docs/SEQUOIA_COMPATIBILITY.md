# Sequoia (macOS 15) compatibility — Private API gap analysis

**Status: evaluation only. No code changes proposed here have been made.**

Everything in the port's Private API surface has been developed and tested against
**macOS 26.5.2 (Tahoe)**. This document answers the question "what breaks on Sequoia, and
what would it cost to support both" by cross-referencing every selector and class the
helpers dispatch against `docs/headers/macos-15.6/` and `docs/headers/macos-26.5.2/`.

Method, so the numbers can be reproduced:

1. Every Objective-C selector-shaped string literal in `Helper/` and `Sources/BBPrivateAPI/`
   was extracted — 425 literals, of which 198 reach `IMCoreRuntime` dispatch.
2. Both header directories were parsed into class → selector indexes
   (26.5.2: 63 classes / 7188 selectors; 15.6: 59 present classes / 6672 selectors).
3. The two were intersected, and every divergence was confirmed by hand against the raw
   header text.

## 0. Read the confidence caveats before acting on any row

`docs/headers/README.md` already states these; they are load-bearing for everything below.

- **15.6 is a borrowed class-dump, not a runtime dump.** It was read from the Mach-O in the
  dyld shared cache, so a **category loaded at runtime by another framework does not appear
  in it**. "Absent on 15.6" therefore means "absent from IMCore's own binary", not "the
  runtime will not dispatch it".
- **15.6 records the NATIVE macOS IMCore; the helper runs against the Catalyst copy.**
  `docs/PRIVATE_API_SURFACE.md` §0 measured a 4-selector delta between those two copies on
  26.5.2 in each direction. So 15.6 is the wrong binary by the same margin, in both
  directions.
- Nothing below has been executed on a Sequoia machine. Every row marked ⚠ or ❓ needs
  `Tools/private-api/probe.sh` on real hardware before a behaviour change ships.

The rows are split by how much that uncertainty matters. The **High** rows correspond to
Messages features that Apple shipped *in* macOS 26 — Screen Unknown Senders, chat
backgrounds, translation-aware editing. Those are absent on Sequoia because the feature is
absent, not because a dump is imperfect, and they can be treated as settled.

---

## 1. Scoreboard

| | Count |
|---|---:|
| Selectors dispatched by the helpers | 198 |
| Present on both 26.5.2 and 15.6 | 127 |
| **Diverge between the two** | **12** (11 present only on 26, 1 only on 15) |
| On classes **neither dump covers** | ~60 |
| Classes the helpers instantiate or message | 25 |
| …of those, covered by `hosts.conf` | 10 → **25** (all; plus 11 more from §5.4) |
| **…still without a Sequoia counterpart** | **15** |

Two distinct problems, and the second is larger than the first:

- **§2** — twelve *confirmed* selector divergences across seven features. Each is small,
  local, and fixable.
- **§3** — fifteen classes carrying ~60 selectors that **no dump has ever covered**, on
  either release. These are not known-broken; they are *unknown*, which is worse, because
  the failure mode is a Sequoia user filing a bug nobody can reproduce.

Structurally, the port is in good shape for this. Every call goes through
`IMCoreRuntime`, which resolves classes and selectors at runtime and checks
`responds(to:)`, arity and return-type encoding before dispatching
([IMCoreRuntime.swift](../Helper/HelperShared/IMCoreRuntime.swift)). `BBInvoke` returns an
`NSError` rather than raising on an unimplemented selector
([HelperObjC.m:236](../Helper/HelperObjC/HelperObjC.m)). **Nothing below can crash
Messages.app on Sequoia.** The failures are hard errors and silently-wrong values, not
aborts.

There is also, today, **no macOS version detection anywhere in `Helper/` or
`Sources/BBPrivateAPI/`** — the only reference to `majorVersion` is a comment in
[FindMyBridge.swift:21](../Helper/BlueBubblesHelper/FindMyBridge.swift) explaining why the
Objective-C helper's version fork was *not* carried forward. That was the right call for
FindMy (IMCore absorbs that fork itself) but it means there is currently no mechanism to
express "do it the other way on 15".

---

## 2. Confirmed divergences

Legend — **Sev**: ⛔ hard failure · ⚠ silently wrong value · ✅ already handled.
**Conf**: High = macOS 26 feature that does not exist on Sequoia · Med = plausible API
refactor, verify on hardware.

### 2.1 ⛔ `report-chat-junk` — `POST /api/v1/chat/:guid/junk`

| | |
|---|---|
| Call site | [IMCoreObjects.swift:207](../Helper/BlueBubblesHelper/IMCoreObjects.swift) |
| 26.5.2 | `-(bool)reportJunk;` and `-(void)reportJunkToCarrierViaRelay:(bool)` |
| 15.6 | **neither exists.** `-(void)reportJunkToCarrier;` (no argument) instead |
| Conf | Med |

`reportJunk` is called unguarded through `callReturningBool`, so on Sequoia the whole route
returns `IMCoreLookupError.raised`. The carrier relay is `responds(to:)`-guarded and so
degrades quietly — but not to an equivalent: it skips the carrier report entirely while the
Sequoia spelling `reportJunkToCarrier` sits right there untried.

Sequoia has the rest of the family: `_messageToReportJunk`, `allMessagesToReportAsSpam`,
`markAsSpam:`, `markAsSpam:isJunkReportedToCarrier:`, `autoReportSpam`,
`markAsAutoSpamReported`.

**Fill:** candidate chain — `reportJunk` → fall back to `markAsSpam:` with
`allMessagesToReportAsSpam.count` (which `markChatAsSpam` already does correctly at
[IMCoreObjects.swift:194](../Helper/BlueBubblesHelper/IMCoreObjects.swift)), and
`reportJunkToCarrierViaRelay:` → `reportJunkToCarrier`.

### 2.2 ⛔ `mark-sender-known` — `POST /api/v1/chat/:guid/known`

| | |
|---|---|
| Call site | [IMCoreBridge.swift:871](../Helper/BlueBubblesHelper/IMCoreBridge.swift) |
| 26.5.2 | `-(void)markAsKnownAndSaveInContacts:(bool)completion:(id)` |
| 15.6 | **the entire mark-as-known family is absent** — no `markAsKnown*` selector at any arity |
| Conf | High |

This is Screen Unknown Senders, a macOS 26 Messages feature. It does not exist on Sequoia
and there is nothing to fall back to. The current code catches the throw and calls
`finish()`, then returns `conversation.filterState()` — so the route reports **success with
an unchanged state**, which reads to a client as "the write landed and did nothing".

**Fill:** detect and report `unavailableOnThisOS`. This is the case that error exists for
([PrivateAPI.swift:624](../Helper/BBPrivateAPIContract/PrivateAPI.swift)). It is already used
seven times — but only ever for a **class** that is absent (`TUCallCenter`,
`IMHandleAvailabilityManager`) or for a hardcoded floor (`markUnread` requires Ventura).
Never yet for a selector that moved, which is the shape every row in this section needs.

### 2.3 ⚠ `get-chat-filter` — `GET /api/v1/chat/:guid/filter`

| | |
|---|---|
| Call site | [IMCoreObjects.swift:164-165](../Helper/BlueBubblesHelper/IMCoreObjects.swift) |
| 26.5.2 | `cachedIsKnownSender`, `inUnknownSendersFilter` |
| 15.6 | **both absent** (same macOS 26 feature as §2.2) |
| Conf | High |

Both reads are `(try? …) ?? false`. On Sequoia every chat therefore reports
`isKnownSender: false, isInUnknownSendersFilter: false` — a plausible-looking lie rather
than an error. The rest of the struct is fine: `isFiltered`, `filterCategory`,
`wasDetectedAsSMSSpam` and `_messageToReportJunk` are all present on 15.6.

**Fill:** make these fields nullable in `ChatFilterState` and emit `null` where the selector
is absent, so a client can tell "not known" from "this OS cannot answer". This is an
additive wire change — a field going from `false` to `null` is the honest signal, and
clients already parse the struct optionally.

### 2.4 ⛔ `refetch-chat-background` — `POST /api/v1/chat/:guid/background/fetch`

| | |
|---|---|
| Call site | [IMCoreObjects.swift:239](../Helper/BlueBubblesHelper/IMCoreObjects.swift) |
| 26.5.2 | `refetchLocalTranscriptBackgroundAssetIfNecessary` |
| 15.6 | **absent**, along with every `transcriptBackground*` selector |
| Conf | High |

Chat backgrounds are a macOS 26 feature. Unguarded `invoke`, so the route throws a raw
lookup error on Sequoia.

Note the sibling read routes — `GET :guid/background` and `:guid/background/info` — are
served from disk and `chat.properties`, not from the helper
([PRIVATE_API_SURFACE.md §1](PRIVATE_API_SURFACE.md)), so they degrade to "no background"
by themselves and need nothing.

**Fill:** `unavailableOnThisOS`, same as §2.2.

### 2.5 ✅ `edit-message` — already correct

| | |
|---|---|
| Call site | [IMCoreObjects.swift:265-278](../Helper/BlueBubblesHelper/IMCoreObjects.swift) |
| 26.5.2 | `editMessageItem:atPartIndex:withNewPartText:newPartTranslation:backwardCompatabilityText:` |
| 15.6 | `editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:` |

Apple added the translation argument in macOS 26 and dropped the 4-argument form. **The code
already handles this** with a three-generation `responds(to:)` candidate chain, newest
first, throwing a named error if none matches.

**This is the pattern the rest of §2 should be rewritten to use.** It is worth noting that
it is also the only place in the port where a version fork was anticipated in advance rather
than discovered.

(The third candidate, `editMessage:atPartIndex:…`, exists on neither release — harmless dead
weight for a macOS older than either dump. Same for `leaveiMessageGroup` at
[IMCoreObjects.swift:131](../Helper/BlueBubblesHelper/IMCoreObjects.swift), absent on both.)

### 2.6 ⛔ `dial-facetime` — `POST /api/v1/facetime/call`

| | |
|---|---|
| Call site | [FaceTimeBridge.swift:355](../Helper/BlueBubblesFaceTimeHelper/FaceTimeBridge.swift) |
| 26.5.2 | `-(void)dialWithRequest:completionWithError:` — block is `(result, error)` |
| 15.6 | **absent.** Has `-(void)dialWithRequest:completion:` with a `void(^)(void)` block, and `-(id)dialWithRequest:` |
| Conf | Med |

The highest-value single break in this document — outbound FaceTime is one of the port's
headline Private API features. `callAwaitingCompletion2` surfaces the invoke failure through
the error channel, so the route fails cleanly with "the dial produced no call", but it fails.

**There is a trap in the obvious fix.** Falling back to `dialWithRequest:completion:` while
still passing a two-argument block is memory-unsafe: Sequoia invokes the block with *no*
arguments, and the block body would then read whatever is in those registers as `result` and
`error` and message them. The safe Sequoia fallback is the **synchronous**
`-(id)dialWithRequest:`, which returns the call directly. The recovery path already in the
code — re-reading `currentCalls` when the completion hands back nothing
([FaceTimeBridge.swift:364](../Helper/BlueBubblesFaceTimeHelper/FaceTimeBridge.swift)) —
means the surrounding logic needs almost no change.

### 2.7 ⚠ FaceTime call payload — `group_uuid` and `callerIDBlocked`

| | |
|---|---|
| Call site | [FaceTimeBridge.swift:865, 877](../Helper/BlueBubblesFaceTimeHelper/FaceTimeBridge.swift) (`decodeCall`) |
| 26.5.2 | `TUCall.conversationGroupUUID`, `TUCall.callerIDBlocked` |
| 15.6 | **both absent.** Has `TUCall.callGroupUUID` and `TUCall.blocked` / `isBlocked` |
| Conf | Med |

Both are `try?`-guarded, so on Sequoia every decoded call reports `group_uuid: null` and
`callerIDBlocked: false`. `group_uuid` is the one that matters — it is the key clients use to
correlate a call with its conversation, and it is a path parameter on
`POST /facetime/:group_uuid/admit` and `GET /facetime/:group_uuid/members`.

Those two routes are **not** affected: they resolve through
`TUConversationManager.conversationsByGroupUUID` and `TUConversation.groupUUID`, both present
on 15.6. Only the `group_uuid` *reported* in call events and dial responses goes null, which
is enough to break a client's correlation.

**Fill:** candidate chain `conversationGroupUUID` → `callGroupUUID`, and
`callerIDBlocked` → `isBlocked`. Both are near-free.

### 2.8 What is confirmed **safe**

Worth stating explicitly, because it is most of the surface:

- **FindMy is completely clean.** Every selector on `IMFMFSession`, `IMFindMyHandle`,
  `IMFindMyLocation`, `IMFindMyDevice`, `FMLHandle`, `FMLLocation`, `FMLPlaceMark` and
  `FindMyLocateSession` used by [FindMyBridge.swift](../Helper/BlueBubblesHelper/FindMyBridge.swift)
  is present on both releases, `IMFMFSession` selector-for-selector identical. The three
  `*UpdateCallback` properties `FindMyLocateSession` loses on Sequoia are not used.
- **Mute / DND is clean** — every `IMMutedChatList` selector present on both, including the
  `muteChat:untilDate:syncToPairedDevice:` / `muteChat:untilDate:` pair that already has a
  fallback.
- **The FaceTime link and conversation surface is clean** — `TUConversationManagerXPCClient`,
  `TUConversationLink`, `TUConversationMember`, `TUHandle`, `TUDialRequest` all match. The
  `TUCallCenter` / `TUConversation` / `TUConversationManager` selectors Sequoia lacks
  (`performTranslationRequest`, `isNearbySession`, `approveExternalParticipants`, …) are not
  called by this port.
- **Core IMChat operations are clean** — `setLocalUserIsTyping:`, `markAllMessagesAsRead`,
  `markLastMessageAsUnread`, `_setDisplayName:`, `leave`, `canLeaveChat`, `deleteAllHistory`,
  `retractMessagePart:`, `sendGroupPhotoUpdate:`, `downloadPurgedAttachments`,
  `_supportsEditMessage`, `updateIsFiltered:`, `markAsSpam:*`, `existingChatWithGUID:`,
  `chatForIMHandles:`.

---

## 3. The larger gap: fifteen classes nobody has ever dumped

`Tools/private-api/hosts.conf` dumped 63 classes. The helpers message **25**. Ten overlapped.
The other fifteen carried roughly 60 selectors with **zero header coverage on any macOS
release** — they could not be evaluated for Sequoia at all, and had never been checked on
Tahoe either; they work there because they were tested there.

> **Half-resolved.** All fifteen are now in `hosts.conf` and dumped on 26.5.2 — see §5.
> That settles what they look like on **Tahoe** (and immediately found two live bugs there),
> but it does **not** answer the Sequoia question: there is no 15.6 dump for any of them, and
> `macos-15.6/` cannot be regenerated without a Sequoia machine. The table below is retained
> as the record of what still needs that machine.

| Class | Framework | Backs |
|---|---|---|
| `CKConversationList` | ChatKit | `add-participant`, `remove-participant`, `delete-chat`, edit/unsend via composition |
| `CKChatController` | ChatKit | `send-message`, `send-multipart`, `send-attachment` |
| `CKComposition` | ChatKit | every send path — text, attachment, audio, effects, mentions |
| `CKMediaObjectManager` | ChatKit | `send-attachment`, `send-multipart` |
| `IMFileTransferCenter` | IMCore | attachment staging, `download-purged-attachment` |
| `IMDPersistentAttachmentController` | IMCore | attachment staging (`_persistentPathForTransfer:…`) |
| `IMMessage` | IMCore | `send-reaction`, subject/effect/thread-id sends |
| `IMChatHistoryController` | IMCore | `delete-message`, `notify-anyways`, `unsend-message` |
| `IMAggregateAttachmentMessagePartChatItem` | IMCore | multipart attachment addressing |
| `IMAccountController` | IMCore | `get-account-info`, `modify-active-alias`, `create-chat` |
| `IMDaemonController` | IMCore | **all inbound events** — typing indicators (rung 2) |
| `IMNicknameController` | IMCore | `get-nickname-info`, `share-nickname`, `should-offer-nickname-sharing` |
| `IMPinnedConversationsController` | IMCore | `update-chat-pinned`, `get-pinned-chats` |
| `IMHandleAvailabilityManager` | IMCore | `check-focus-status` |
| `IDSIDQueryController` | IDS | `check-imessage-availability`, `check-facetime-availability` |

That list is most of what the Private API actually does. **Sending a message on Sequoia goes
entirely through classes this analysis cannot speak to.**

Two of them deserve specific worry:

- **`IMDaemonController` + its `listener`.** [EventObservation.swift](../Helper/BlueBubblesHelper/EventObservation.swift)
  attaches to `_IMLegacyDaemonListener` via `addHandler:` and duck-types
  `account:chat:style:chatProperties:messageReceived:`. Every one of those was measured on
  26.5.2 and none is in any dump. If the callback signature differs on Sequoia, typing
  indicators silently never fire — and the code already knows this failure is invisible,
  which is why it reports a `rung` in the registration handshake.
- **`IMPinnedConversationsController`.** Two selector generations are already tried
  (`setPinnedChats:withUpdateReason:` → `setPinnedConversationIdentifiers:withUpdateReason:`)
  at [IMCoreBridge.swift:693-716](../Helper/BlueBubblesHelper/IMCoreBridge.swift), which is
  evidence Apple has renamed this surface at least once and may have done so again between
  15 and 26.

Also uncovered, and not class members so no dump would catch them: the four
`__kIM*AttributeName` string constants used to build attachment and mention runs
([IMCoreObjects.swift:693-707](../Helper/BlueBubblesHelper/IMCoreObjects.swift)), and
`CSDConversationManagerClientsShouldConnectNotification`
([FaceTimeBridge.swift:157](../Helper/BlueBubblesFaceTimeHelper/FaceTimeBridge.swift)). These
are `__cstring` literals; a `dlsym` for them fails, which `docs/headers/README.md` already
warns is a false negative. They need `Tools/private-api/notifications.sh`, not a class dump.

---

## 4. What filling the gap requires

Four pieces of work, roughly in dependency order. **Step 1 is the one that unblocks
everything else**, and it is a hardware problem, not a code problem.

### Step 1 — Get a real Sequoia dump. Nothing else is trustworthy without it.

- Add the fifteen classes from §3 to `Tools/private-api/hosts.conf`. Do this **first**, and
  re-run `dump-headers.sh` on 26.5.2 too, so both releases carry the same class set and the
  diff stays meaningful. This alone converts §3 from "unknown" into a table like §2 for
  whichever release we have.
- Run `dump-headers.sh` on a real macOS 15 machine. It overwrites `macos-15.6/` in place and
  supersedes the borrowed dump, resolving the Catalyst-vs-native and runtime-category
  caveats in §0 at a stroke.
- Run `notifications.sh` there too, for the `__kIM*` constants and the CSD notification.
- Run `probe.sh` for the daemon-listener callback signatures in §3, which a class dump alone
  will not settle.
- macOS 14 (Sonoma) is in the support target and has **no dump at all** — limneos publishes
  none. Same treatment, and it will surface a third generation of some of these selectors.

### Step 2 — Give the helper a version identity

Not to branch on. To *report* with.

`ProcessInfo.processInfo.operatingSystemVersion`, added to the registration handshake
alongside the existing `events` rung at
[HelperSocketClient.swift:230-236](../Helper/HelperShared/HelperSocketClient.swift). That
channel exists precisely because `os_log` from an injected dylib in a sandboxed host does not
reliably reach `log show`, and it already carries one capability field.

Deliberately **not** an OS-version fork at the call sites. `responds(to:)` is a better
predicate than a version number — it is correct across the Catalyst/native split, across
point releases, and across a beta that moves a selector early — and it is what the whole
`IMCoreRuntime` design is built on. The version is for telling the *user* why something is
unavailable, and for a bug report to be actionable.

### Step 3 — Make every divergence in §2 use one of two shapes

The port already contains both; neither is new machinery.

**Shape A — candidate chain**, for a selector that was renamed or changed arity. Copy
`IMChat.editMessage` verbatim: newest spelling first, `responds(to:)` on each, named throw if
none matches. Applies to §2.1 (both selectors), §2.6, §2.7 (both).

**Shape B — `unavailableOnThisOS`**, for a feature that genuinely does not exist on the older
release. Applies to §2.2 and §2.4. The error case is already defined and already renders a
clean sentence to clients; what is missing is reaching it from a *selector*-level absence
rather than only a class-level one.

For §2.3 the fix is neither: it is a *nullable field*, so "this OS cannot answer" is
distinguishable from "no".

A shared helper is worth extracting rather than repeating the chain by hand:

```swift
// IMCoreRuntime
static func firstResponding(_ target: AnyObject, _ candidates: [String]) -> String?
```

…which makes each call site three lines and makes the set of version-forked selectors
greppable, which the current hand-rolled chains are not.

### Step 4 — Report capability, do not just fail

The external HTTP API must not change shape by macOS version — a client cannot be asked to
branch on the server's OS. Two mechanisms preserve that:

- **Per-route**: a route whose selector is absent returns the existing
  `unavailableOnThisOS` error with a `requires:` string. Same route, same schema, honest
  failure. This is already the contract; it just needs to be reached instead of a raw
  `IMCoreLookupError.raised` leaking through.
- **Up front**: extend the capability report in the registration handshake from one field
  (`events`) to a probed set, so the server can tell a client *before* it calls that
  `chat.markKnown` is unavailable on this host. `POST /api/v1/facetime/call` failing at dial
  time is a much worse experience than a client that knew.

Per [memory: security actions must alert, not just log], a Private API capability the user is
silently missing should raise a `UserAlert` through `AlertCenter` naming the feature and the
macOS version — the same reasoning that put the `events` rung on the wire rather than in a
log nobody reads.

### What this does *not* require

- No `@available` annotations or compile-time forking. The helper is one dylib injected into
  whatever Messages is running; the branch has to be at runtime regardless.
- No change to the wire protocol between server and helper.
- No change to any route path, method, or request schema. §2.3's `false` → `null` is the only
  response-shape change, and it is additive and strictly more informative.

---

## 5. What the re-dump found — three live bugs on Tahoe

Adding the fifteen classes to `hosts.conf` and re-running `dump-headers.sh` on 26.5.2 was
meant to prepare for a Sequoia comparison. It did that — but it also resolved selectors
that had never been checked against a header on *any* release, and three of them **do not
exist on the host this port was developed against**. All three are call sites that fail
today, on Tahoe; none is a Sequoia problem.

Re-dump receipts: 63 → 78 headers, the 63 existing files byte-identical (same build, 25F84),
no `NOT PRESENT` in the new fifteen.

### 5.1 ✅ FIXED — `share-nickname` was dead on Tahoe: wrong arity, not a missing feature

| | |
|---|---|
| Call site | [IMCoreBridge.swift:1123-1131](../Helper/BlueBubblesHelper/IMCoreBridge.swift) |
| Tried | `whitelistHandlesForNicknameSharing:forChat:`, then `allowHandlesForNicknameSharing:forChat:` |
| On 26.5.2 | **neither exists.** `IMNicknameController` has `allowHandlesForNicknameSharing:forChat:fromHandle:forceSend:` and `allowHandlesForNicknameSharing:fromHandle:forceSend:` |

Both candidates fail `responds(to:)`, so the route falls through to
`unavailableOnThisOS(method: "shareNickname", requires: "an IMNicknameController sharing
selector this macOS has")`. The message is actively misleading: this macOS *has* one, at an
arity the chain never tries. `POST` to the share-nickname route has presumably never worked.

`TODO.md:298` already lists `shareNickname` under "re-check every `unavailableOnThisOS`
branch per version", but frames it as *possibly inverted on an older OS*. The dump says
something sharper — it is wrong on the current OS, and the fix is local.

**Fixed.** `shareNickname` now walks a four-generation arity chain, newest first. The
`fromHandle:` argument is the Mac's own `IMAccount.loginIMHandle`, reached through a new
`IMAccountController.loginHandle()`; `forceSend:` is false, since re-sending a nickname the
recipient already has is not what "share" means.

That `fromHandle:` is an `IMHandle` and not a handle-ID string was **read off the
disassembly, not guessed**: `Tools/private-api/trace.sh` shows the local method converting
every other handle argument with `_handleIDsForHandle:` before forwarding to
`IMDaemonAnyProtocol.allowHandleIDsForNicknameSharing:onChatGUIDs:fromHandle:forceSend:` —
and the daemon's parameter names record each conversion (`allowHandles` → `allowHandleIDs`,
`forChat` → `onChatGUIDs`). `fromHandle:` keeps its name across the boundary, so it keeps
its type.

**A note on the test that did not catch this.** `IMCoreSelectorTests` already pinned
`allowHandlesForNicknameSharing:forChat:fromHandle:forceSend:` and passed, while the bridge
called a two-argument selector that does not exist. Pinning that a selector EXISTS says
nothing about whether the bridge calls it. The test now also records the two legacy
spellings as *absent*, so a macOS that brings them back is a visible change.

### 5.2 ✅ FIXED — `check-focus-status` was skipping a refresh that is available

| | |
|---|---|
| Call site | [IMCoreObjects.swift:1196-1203](../Helper/BlueBubblesHelper/IMCoreObjects.swift) |
| Tried | `_fetchUpdatedStatusForHandle:completion:` (leading underscore) |
| On 26.5.2 | absent — but **`fetchUpdatedStatusForHandle:completion:` exists**, no underscore |

The comment above the guard states the selector "no longer exists" on macOS 26 and treats
the refresh as optional, returning the manager's cached answer. That conclusion is right for
the underscored spelling and wrong for the feature: `IMHandleAvailabilityManager` also
exposes `fetchPersonalAvailabilityWithCompletion:` and
`fetchUpdatedStatusAndUpdateCachesForHandle:lastKnownStatus:`.

Consequence is mild — a stale focus status rather than an error, which is what the code
already promises — but it is stale unnecessarily.

**Fixed.** The guard now tries `fetchUpdatedStatusForHandle:completion:` first and falls
back to the underscored spelling, and the selector is pinned in `IMCoreSelectorTests`.

The completion block stays zero-parameter, which is safe under either spelling — a block
declaring no parameters is called correctly however many arguments IMCore passes, because it
never reads the argument registers. The reverse is the §2.6 trap.

### 5.3 Confirmed fine

Where a fallback chain's *primary* leg exists, the missing legs are harmless dead weight and
need no action. Pinning is the clearest case: `setPinnedChats:withUpdateReason:` and
`pinnedConversationIdentifierSet` are both present on 26.5.2, so
`update-chat-pinned` / `get-pinned-chats` work; the fallback legs
`setPinnedConversationIdentifiers:withUpdateReason:` and `pinnedChats` are absent, which is
exactly what `TODO.md:298` predicted ("which Tahoe has REMOVED").

Everything else the fifteen classes back resolved cleanly on 26.5.2 — the whole send path
(`CKComposition`, `CKChatController`, `CKMediaObjectManager`, `IMFileTransferCenter`,
`IMDPersistentAttachmentController`), `IMMessage`, `IMChatHistoryController`,
`IDSIDQueryController`, and `IMDaemonController.listener`.

### 5.4 ✅ ADDED — the classes reached only as return values

A second blind spot, and a subtler one: a class the helper never names, because it only ever
receives instances of it. `IMChatRegistry.existingChatWithGUID:` hands back an `IMChat`, and
that class was dumped — but `activeIMessageAccount` hands back an `IMAccount`, `-listener`
hands back an `_IMLegacyDaemonListener`, and neither name appears anywhere in `Helper/`, so
the sweep that produced §3 could not see them.

Eleven more added to `hosts.conf` and dumped: `CKConversation`, `CKMediaObject`,
`IMMessageItem`, `IMFileTransfer`, `IMAccount`, `IMHandle`, `_IMLegacyDaemonListener`,
`IMDaemonListener`, and the protocols `IMDaemonProtocol`, `IMDaemonListenerProtocol`,
`IMDaemonAnyProtocol`.

`_IMLegacyDaemonListener` is the one that mattered — 127 methods carrying `addHandler:` and
the `account:chat:style:chatProperties:messageReceived:` callbacks, i.e. **the entire
inbound-event path**, previously verified only by an ad-hoc probe recorded in a comment.

Unresolved selector references across the whole helper are now **26, down from 45**, and the
residue is benign: JSON keys and Foundation methods (`mailto:`, `path`, `absoluteString`),
singleton-accessor candidates, `generateMedia:` (documented as living in a plugin bundle that
only loads inside Messages), and the deliberately-absent legacy legs of the fallback chains
in §2.5, §5.1 and §5.2 — which is what a healthy chain looks like from the outside.

Checked while there and **clean**: the two long `IMMessage` initializers behind `send-message`
and `send-reaction` are built by string concatenation across three source lines, which made
them look unresolved. Reassembled, both exist verbatim on 26.5.2. Not a third §5.1.

---

### 5.5 ✅ FIXED — `started-typing` could never fire

| | |
|---|---|
| Call site | [EventObservation.swift:195](../Helper/BlueBubblesHelper/EventObservation.swift) |
| Tried | `isIncomingTypingMessage` on the `IMMessageItem` the daemon listener hands over |
| On 26.5.2 | **absent.** `IMMessageItem` has `isTypingMessage`, `isCancelTypingMessage`, `isTypingOrCancelTypingMessage`, `isIncomingTypingOrCancelTypingMessage`, `isGroupTypingMessage` — but no `isIncomingTypingMessage` |
| On 15.6 | absent from that dump too |

The worst of the three, because of how it fails. `DaemonEventHandler.boolean` answers `false`
for a selector that is absent, so:

```swift
let isTyping = Self.boolean(item, "isIncomingTypingMessage")  // hardcoded false
let isCancel = Self.boolean(item, "isCancelTypingMessage")    // works
guard isTyping || isCancel else { return }                    // only a CANCEL gets through
EventObservation.emit?(.typing(chat: chat, isTyping: isTyping && !isCancel))  // always false
```

Every branch is individually defensible and the composition is dead. Only a cancel reaches
the guard, and `isTyping && !isCancel` is false when it does — so the helper emitted
`stopped-typing` and **`started-typing` could not fire at all**. Typing indicators
half-worked, in the direction nobody files a bug about: an indicator that never appears
looks like nobody is typing.

This is the failure `EventObservation`'s own header comment predicts for a swizzle — "a
private selector is renamed, the hook silently stops firing, and the user reports 'typing
indicators stopped working' with nothing in any log" — arriving through a `responds(to:)`
guard instead. Runtime lookup made it survivable; it did not make it visible. Only a header
did that, which is the argument for §3 in one bug.

**Fixed.** `isIncomingTypingMessage` stays first (a macOS that has it is the most precise
answer) and falls back to `isTypingMessage`. Because that spelling is **not directional**
where the one it replaces was, the handler now also drops items where `isFromMe` — without
which the helper would report the user's own typing back to every connected client on every
keystroke. Selectors pinned in `IMCoreSelectorTests`, with `isIncomingTypingMessage`
recorded as absent.

---

## 6. When the Sequoia headers arrive — the runbook

Everything below runs on this machine. None of it needs the Sequoia box; it is the "compare
and check" half, and the tools are checked in so the answer is reproducible rather than
reconstructed from scratch each time.

### Step A — get the headers in

**If they came from `limneos-scrape.js`** (the stopgap, 20 of the 26 missing classes):

```bash
Tools/private-api/import-limneos.mjs --dry-run ~/Downloads/limneos-macos-15.6-part2.json
Tools/private-api/import-limneos.mjs ~/Downloads/limneos-macos-15.6-part2.json
```

Dry-run first and read the report. It has four outcomes and only one of them is good —
`FAILED TO PARSE` means the page had no `@interface`, which usually means the framework name
in the scraper's target list is wrong for that release rather than that the class is gone.
The importer refuses to overwrite anything stamped by `dump-headers.sh`, because a real
runtime dump beats a scraped one and must never be silently replaced by it.

**If they came from `dump-headers.sh` on a real Sequoia machine**, they are already in the
right shape and the right place — drop the directory in and skip to Step B. That output
supersedes the scrape entirely; delete the scraped files rather than merging them.

### Step B — compare

```bash
Tools/private-api/compare-releases.py
```

Four buckets, and **the one to read first is `UNCOMPARABLE`** — it should go to zero for
every class the new headers cover. That bucket exists because "absent from 15.6" and "on a
class 15.6 never dumped" are different answers, and reporting them together is the single
mistake this document exists to prevent. Right now it stands at **61**; each one is a real
question the headers will settle.

Then read `PRESENT ON macos-26.5.2, ABSENT ON macos-15.6` — that is §2's table, regenerated.
Anything new in it is a Sequoia regression this document has not accounted for.

```bash
Tools/private-api/compare-releases.py --markdown     # paste straight into §2
Tools/private-api/compare-releases.py --unresolved   # the residue, see below
```

### Step C — triage each new row

For every selector that turns up absent on Sequoia, the question is which of three shapes it
takes, and §4 has the full argument:

| If Sequoia has… | Do this | Precedent |
|---|---|---|
| the same call under another name or arity | candidate chain, newest first | §2.5, §5.1 |
| no equivalent, because the feature is macOS 26 | `unavailableOnThisOS` | §2.2, §2.4 |
| no equivalent, and the value is *read* not written | make the field nullable | §2.3 |

**Check the argument shapes, not just the names.** §2.6 is the standing example: Sequoia's
`dialWithRequest:completion:` takes a `void(^)(void)`, and reusing our two-argument block
with it reads uninitialized registers as `result` and `error`. A name that matches is not a
signature that matches.

### Step D — what the tools will not tell you

`compare-releases.py`'s `UNRESOLVED` bucket is 53 and mostly benign by construction — our own
method names inside `unavailableOnThisOS(method:)`, and the deliberately-absent legacy legs
of the chains in §2.5, §5.1, §5.2 and §5.5, which is what a healthy chain looks like from
outside. Three things in it are real and no class dump will ever settle them:

- **The `__kIM*` attribute constants** and
  `CSDConversationManagerClientsShouldConnectNotification`. String literals in `__cstring`,
  not class members — `Tools/private-api/notifications.sh`, on both releases.
- **`generateMedia:`**, which lives in a plugin bundle that only loads inside Messages.
- **The daemon listener's callback signatures.** `_IMLegacyDaemonListener` is dumped now, so
  `addHandler:` is covered — but that a handler implementing
  `account:chat:style:chatProperties:messageReceived:` actually gets called is a `probe.sh`
  question. §5.5 is what that surface failing quietly looks like.

### Step E — make it a build failure next time

Once **both** sides are real runtime dumps rather than a scrape:

```bash
Tools/private-api/compare-releases.py --strict     # exit 1 on any divergence
```

That is the point at which "what did Apple move this time" stops being an investigation and
becomes a red test — which is the whole reason the header directories are checked in.

---

## 7. Suggested order

| | Work | Blocked on |
|---|---|---|
| ~~1~~ | ~~Add the 15 classes to `hosts.conf`; re-dump 26.5.2~~ — **done**; found §5.1 and §5.2 | — |
| ~~1b~~ | ~~Fix §5.1, §5.2 and §5.5 — Tahoe bugs~~ — **done**; builds, 102 helper tests pass | — |
| ~~1c~~ | ~~Add the return-value-only classes to `hosts.conf`~~ — **done**; 11 added, §5.4 | — |
| 2 | Real `dump-headers.sh` + `notifications.sh` + `probe.sh` run on macOS 15 | **a Sequoia machine** |
| 3 | Same on macOS 14 | a Sonoma machine |
| 4 | Re-run this analysis against the real dumps; fold §3 into §2 | 1–3 |
| 5 | `firstResponding` helper + Shape A for §2.1, §2.6, §2.7 | 4 (2.6 especially — the block-signature trap) |
| 6 | Shape B for §2.2, §2.4; nullable fields for §2.3 | 4 |
| 7 | OS version + probed capability set in the registration handshake; `UserAlert` on a missing capability | 5, 6 |

Steps 5 and 6 are each a few hours. Step 2 is the whole project, and everything downstream of
it is guesswork until it happens.
