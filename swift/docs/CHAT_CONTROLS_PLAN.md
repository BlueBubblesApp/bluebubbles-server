# Chat controls — implementation plan

Five conversation-level capabilities from `PRIVATE_API_SURFACE.md` Part I, taken from survey
to shipping code:

| # | Feature | IMCore/ChatKit surface | Confidence |
|---|---|---|---|
| 1 | Mute / DnD (snooze) | `IMMutedChatList`, `IMChat -setMuteUntilDate:` | **High** — selectors and on-disk store both verified |
| 2 | Clear chat history | `IMChat -deleteAllHistory` | **High** — already wrapped in `IMCoreObjects.swift:142`, never exposed |
| 3 | Mark sender known | `IMChat -markAsKnownAndSaveInContacts:completion:` | **High** — block argument already supported by `BBInvoke` |
| 4 | Mark spam / report junk | `IMChat -markAsSpam:`, `-reportJunk`, `-updateIsFiltered:` | **Medium** — one argument's meaning is unresolved (§5.2) |
| 5 | Chat wallpaper | `IMChat -setTranscriptBackgroundAndSendToChat:transferID:` + PosterKit | **Read: high. Write: needs a spike** (§5.1) |

Everything below is layered onto machinery that already exists. Nothing here needs a new
helper, a new socket, a new host app, or a change to the transport.

---

## 0. What was measured on this machine, today

macOS 26.5.2 (25F84, arm64e) — the same build `docs/headers/macos-26.5.2/` was dumped from.
Facts that were read from the running system rather than inferred are marked **MEASURED**.

**MEASURED — mute state is a plain plist, and it is the live store.**
`~/Library/Preferences/com.apple.MobileSMS.CKDNDList.plist`:

```
"CKDNDListKey" => {
    "1B18CE8F964B3E16194004673427BF442B1D82EE" => 64092211200
    "5DAD4D9D-F17D-4449-BD04-6BA126F8B4BC"     => 64092211200
    ... 9 entries
}
```

Disassembly of both ends confirms the domain and key rather than inferring them from the
filename — `-[IMMutedChatList mutedChatList]` and
`-[IMMutedChatList _synchronizeMutedChatList:syncToPairedDevice:]` both carry the constants
`"com.apple.MobileSMS.CKDNDList"` and `"CKDNDListKey"`, and the write additionally posts
`"com.apple.MobileSMS.CKDNDList.changed"`. `CKConversationMutedChatListMigrator` is legacy
migration *into* this store, not a competing one — the plist's `CKDNDMigrationKey => 2` is
that migration's receipt.

Keys are `IMMutedChatList` *mute identifiers* — a SHA-1-shaped hash for 1:1 chats, a group
UUID for groups — not chat GUIDs. So an offline read is possible in principle but requires
reproducing
`-muteIdentifiersForChatStyle:groupID:domainIdentifiers:participantIDs:lastAddressedHandleID:originalGroupID:chatIdentifier:`.
Reading through the helper is one selector; do that.

**MEASURED — the values are UNIX epoch seconds, and mute-forever is `[NSDate distantFuture]`.**
This is the part the survey got wrong, and it is the difference between a working mute and a
silent no-op. `-[IMMutedChatList muteChatWithMuteIdentifiers:untilDate:syncToPairedDevice:]`
stores `[untilDate timeIntervalSince1970]` boxed with `numberWithDouble:` — **not**
`timeIntervalSinceReferenceDate`. And `64092211200` is exactly `[NSDate distantFuture]` in
that scale (`63113904000 + 978307200`), i.e. 4001-01-01, not a magic number Apple invented.

`PRIVATE_API_SURFACE.md` §2 guesses that "`nil` date reads as mute-indefinitely". Do not rely
on it: a nil date reaches `[nil timeIntervalSince1970]`, which is `0.0`, which stores an unmute
date of 1970 — and the read path is
`-[IMMutedChatList isMutedChatForMuteIdentifiers:]` → `unmuteDateForMuteIdentifiers:` →
`[date compare:[NSDate date]]`, so a 1970 unmute date reads as **not muted**. Indefinite is
written as `Date.distantFuture`, explicitly.

That same read path is why granular snooze works at all: mute state is a stored instant
compared against now, so a timed mute expires on its own with nothing to schedule.

**MEASURED — the transcript background is a poster archive, and the watch copy is a plain PNG.**
`~/Library/Messages/TranscriptBackgroundCache/` on this account holds one background:

```
9EB9A5C2-…-C22DE7A99A1C                 AA01 …  ← Apple Archive (poster bundle)
9EB9A5C2-…-C22DE7A99A1C-watchBackground  bplist:
    backgroundImageData   = <PNG, 726931 bytes>
    extensionIdentifier   = "com.apple.transcriptBackgroundPoster.DynamicExtension"
    isHighKey             = false
    luminance             = 0.2
```

**MEASURED — chat backgrounds are PosterKit posters in the `PRPosterRoleBackdrop` role**, and
three extensions vend them:

| Extension | Bundle id | Roles |
|---|---|---|
| Dynamic (animated scenes) | `com.apple.transcriptBackgroundPoster.DynamicExtension` | Backdrop |
| Gradient | `com.apple.transcriptBackgroundPoster.GradientExtension` | Backdrop |
| Photos | `com.apple.PhotosUIPrivate.PhotosPosterProvider` | LockScreen, IncomingCall, **Backdrop** |

`PRStaticDescriptors` on the first two is a single descriptor, `hero`.

**MEASURED — how ChatKit builds a background poster.** Disassembling
`+[CKPosterConfigurationBuilder createPosterConfigurationForExtensionIdentifier:completion:]`:

```
 +52  IMWeakLinkClass                   "PRUISPosterConfigurationBuilder" / "PosterKit"
 +80  msgSend  initWithProvider:role:   role = PRPosterRoleBackdrop   ← const
 +92  msgSend  buildPosterConfigurationWithCompletion:
```

and `PRUISPosterConfigurationBuilder` (PosterBoardUIServices) carries
`sessionInfo: PRSPosterUpdateSessionInfo`, whose `assetURLs: NSDictionary` is how an image
file reaches a poster provider. That is the thread §5.1 pulls.

**MEASURED — `-[CKConversation setPendingTranscriptBackground:transferID:]` is UI only**: it
retains two objects and posts an `NSNotification`. The real write is IMCore's
`-[IMChat setTranscriptBackgroundAndSendToChat:transferID:]`, exactly as `PRIVATE_API_SURFACE.md` §1 says.

**MEASURED — `-[IMChat markAsSpam:isJunkReportedToCarrier:]` is a query, not a flag flip**: it
runs `_performQueryWithKey:@"MarkAsSpam" loadImmediately:block:`, calls
`-_setCountOfMessagesMarkedAsSpam:`, reads the `restoredFromBlackhole` chat property, and
returns an `integerValue`. So the `unsigned long long` return is a **count of messages**, and
the argument is very likely the same kind of quantity rather than a reason code — see §5.2.

**MEASURED — the test conversation.** `bluebubblesapp@gmail.com` is chat ROWID 50, GUID
`any;-;bluebubblesapp@gmail.com`, style 45, `service_name = iMessage`. Note the `any;-;`
prefix: do not hardcode `iMessage;-;` in the test commands.

**MEASURED — WebP is not a problem.** ImageIO on this machine decodes
`~/Downloads/wallpaper.webp` (338×601) fine, and `ImageConverter.convert` in
`Sources/BBSystem/MediaConversion.swift:36` already goes through `CGImageSource`. The format
question turns out to be the wrong question anyway: nothing in this path takes an image — it
takes a *poster archive*. The image is an input to building one, so it is converted to PNG
server-side (one call) before it ever reaches the helper, and WebP never crosses the boundary.

---

## 1. Cross-cutting prerequisites

These land first because three of the five features need them.

### 1.1 `BBInvoke` discards non-object returns — **DONE**

`Helper/HelperObjC/HelperObjC.m:268` only reads the return value when the encoding is `@` or
`#`. Every other return type — including `BOOL deleteAllHistory` and
`unsigned long long markAsSpam:` — comes back as `nil`, so the caller cannot tell success from
failure or read the count.

`IMCoreRuntime.bool(_:_:)` and `.integer(_:_:)` cover zero-argument getters through typed IMPs;
neither can take arguments, and neither runs inside the exception barrier for the argument
marshalling `BBInvoke` does.

**Shipped**: `BBBoxedScalarReturn` in `HelperObjC.m` reads the return at its declared width
(`c C B s S i I l L q Q f d`, each into its own C type — a `char` read into a wider local
carries whatever was beside it) and boxes it as an `NSNumber`. Object and void returns are
untouched. `IMCoreRuntime` gained `number(_:_:_:)`, `callReturningBool` and
`callReturningInteger`; the last two are the ones with arguments, which `bool(_:_:)` and
`integer(_:_:)` cannot take because they go through a typed IMP.

Covered by three tests in `Tests/HelperTests/IMCoreRuntimeTests.swift` against a local
`ScalarReturnTarget`: every width round-trips, `false` is `false` rather than a dropped nil, a
void return is still nil and asking it for a number is an error, and object returns are
unchanged.

### 1.2 One new additive route group

All twelve routes below go into a single `AdditiveRoutes.chatControls` group in
`Sources/BBHTTPAPI/RouteTable.swift` (next to `chatPinning`, line 527), mounted at
`apiVersion: RouteTable.latestVersion` — i.e. `/api/v2/chat/…`. Registered from
`ServerComposition.swift:476` inside the existing `if additiveEndpoints` block.

Rules this group has to respect, all of which have bitten before:

- **The v1 chat serializer does not change.** `Serializers.swift:261` is pinned by the parity
  harness; adding `isMuted` to a chat object fails it on every response. Mute and filter state
  are read through their own v2 routes.
- **Literal before parameter.** Every route here is `:guid/<literal>`, so within the group
  ordering is free — but `DELETE :guid/messages` must not be added to the *v1* chat group,
  where `DELETE :guid/:messageGuid` would swallow it and delete a message whose GUID is the
  literal string "messages".
- **There is no `chats:read` scope.** `Scope` has five cases
  (`AuthenticationScheme.swift:19`). A route that names none gets the default, `messages:read`
  — which is what `chat.pinned` relies on. Follow that for the state reads; `GET :guid/background`
  names `attachmentsRead` explicitly to match `chat.groupIcon`, and every write takes
  `chatsWrite`. `requires: .privateAPI` on everything except the two background reads, which
  come off disk.

### 1.3 Selector pinning

Every new selector goes into `Tests/HelperTests/IMCoreSelectorTests.swift` as it lands. Two
things to fix while there:

- That suite dlopens `/System/Library/PrivateFrameworks/IMCore.framework/IMCore` — the **macOS**
  copy. `PRIVATE_API_SURFACE.md` §0 established that Messages talks to the *iOSSupport* copy and
  that the two `IMChat`s differ. The suite is therefore pinning selectors on a binary the
  helper never calls. It happens to agree for everything pinned so far; it will not agree
  forever. Either the test host is built `-target arm64-apple-ios…-macabi` or the suite gains a
  comment stating the limitation. Do the comment now, the build change separately — it is not
  this feature's job.
- `IMMutedChatList` lives in IMSharedUtilities, which the suite already loads.

### 1.4 Alerting on destructive actions

Clearing history and reporting junk destroy or reclassify a user's conversation on Apple's
side, from a remote client. Both raise a `UserAlert` through `AlertCenter` naming the chat —
logging is not enough, per the standing rule in CONTRIBUTING ("logging never notifies").

---

## 2. Feature 1 — Mute / Do Not Disturb

The one clients ask for most, and the cheapest to build.

### Contract (`Helper/BBPrivateAPIContract/PrivateAPI.swift`)

```swift
public struct ChatMuteState: Codable, Sendable {
    public let isMuted: Bool
    /// Absent when not muted, or when muted indefinitely.
    public let mutedUntil: Date?
    public let isIndefinite: Bool
}

public struct ChatMuteRequest: Codable, Sendable {
    public let chat: ChatGUID
    /// `nil` mutes indefinitely — the "Hide Alerts" toggle with no expiry.
    public let until: Date?
    /// Whether the change propagates to the paired iPhone. Exposed, not hardcoded.
    public let syncToPairedDevice: Bool
}

func muteState(chat: ChatGUID) async throws -> ChatMuteState
func setMute(_ request: ChatMuteRequest) async throws -> ChatMuteState
func unmute(chat: ChatGUID, syncToPairedDevice: Bool) async throws -> ChatMuteState
```

Granularity comes from `until` being an absolute instant. Anything the iPhone offers — an
hour, until this evening, until tomorrow, forever — is a date the client computes, so the
server never grows a hardcoded menu of durations. The HTTP layer additionally accepts
`durationSeconds` as a convenience and converts it.

### Helper (`IMCoreObjects.swift`, `IMCoreBridge.swift`)

A new `IMMutedChats` wrapper next to `IMChatRegistry`:

```swift
enum IMMutedChats {
    static func list() throws -> AnyObject            // +[IMMutedChatList sharedList]
    static func isMuted(_ chat: IMChat) throws -> Bool
    static func unmuteDate(for chat: IMChat) throws -> Date?
    static func mute(_ chat: IMChat, until: Date?, sync: Bool) throws
    static func unmute(_ chat: IMChat, sync: Bool) throws
}
```

Preferred path is the list — it is the store, and it is what takes `syncToPairedDevice:`:

```
-muteChat:untilDate:syncToPairedDevice:        write
-muteIdentifiersForChat: + -unmuteChatWithMuteIdentifiers:syncToPairedDevice:   unmute
-isMutedChat: / -unmuteDateForChat:            read
```

Fall back to `IMChat -setMuteUntilDate:` / `-isMuted` / `-muteUntilDate` when `IMMutedChatList`
or a selector on it is missing, matching how `setPinned` handles its two eras
(`IMCoreBridge.swift:668`). Unmuting through the fallback is `setMuteUntilDate:nil`.

**Resolved by spike 6.1** (§6.1, and see §0): indefinite is `Date.distantFuture`, never
`nil` — `nil` stores an unmute date of 1970 and reads back as *not muted*. On read, treat a
date at or past `distantFuture` as `isIndefinite` rather than surfacing the year 4001 to a
client. Only the fallback path (`IMChat -setMuteUntilDate:nil`) is still unverified for
unmuting; the list's `-unmuteChatWithMuteIdentifiers:syncToPairedDevice:` is the path that
removes the entry outright and is preferred for exactly that reason.

### Server

- `PrivateAPIClient`: actions `get-chat-mute`, `set-chat-mute`, `unmute-chat`.
- `ChatInterface`: `muteState(guid:)`, `setMute(guid:until:sync:)`, `unmute(guid:sync:)`,
  each through `requirePrivateAPI(for:)`.
- Handlers in `WriteHandlers.registerChatActions`.

### Routes

```
GET    /api/v2/chat/:guid/mute     chat.muteState
POST   /api/v2/chat/:guid/mute     chat.mute     {until | durationSeconds | indefinite, syncToPairedDevice}
DELETE /api/v2/chat/:guid/mute     chat.unmute   {syncToPairedDevice}
```

All three return the resulting `ChatMuteState`, so a client never has to re-read to find out
what it did.

### Optional, later

`__kIMMutedChatListDidChangeNotification` is a rung-1 notification. Wiring it in
`EventObservation.swift` gives clients a push when the user mutes on their phone. Not required
for the feature; do it after the writes work.

---

## 3. Feature 2 — Clear chat history

`IMChat -deleteAllHistory` is already wrapped at `IMCoreObjects.swift:142` and nothing calls
it. The header says it returns `BOOL`, so §1.1 lands first if the result is to be believed.

Distinct from `deleteChat`, which goes through `CKConversationList -deleteConversation:` and
removes the conversation itself (`IMCoreBridge.swift:512` documents that this exact confusion
has already been made twice). Clearing keeps the conversation and empties it.

- Contract: `func clearChatHistory(_ chat: ChatGUID) async throws`
- Action: `clear-chat-history`
- Route: `DELETE /api/v2/chat/:guid/messages`, `scope: .chatsWrite`, `requires: .privateAPI`,
  and the body must carry `{"confirm": true}` — a destructive call should not be reachable by
  a mistyped URL.
- Raise a `UserAlert` naming the chat (§1.4).
- The server's chat.db change detector polls for *new* rows; a mass delete is invisible to it.
  Check whether anything caches message counts per chat and invalidate it. Clients are expected
  to re-query the chat after this call; say so in the route's doc comment.

Deliberately **not** built: recovering from Recently Deleted. `-recoverableMessagesCount` and
the registry's recovery calls are a separate feature (`PRIVATE_API_SURFACE.md` §3), and
shipping "clear" without "recover" is the same trade Messages itself makes.

---

## 4. Feature 3 — Mark sender as known

```objc
- (void)markAsKnownAndSaveInContacts:(bool)arg0 completion:(id /* block */)arg1;
```

Per §3 of the survey this is the composite action: `updateIsFiltered:` +
`_chat_acceptChat:` + `markChatsAsReviewed:`. Do not reimplement those three; call this.

- The `bool` and the block both marshal correctly through `BBInvoke` today — the block
  handling at `HelperObjC.m` is explicitly built for IMCore completion handlers.
- Bridge to `async` with a `CheckedContinuation` and the `Box` pattern already used in
  `IMChatHistory.load` (`IMCoreObjects.swift:784`), including its timeout, so a completion
  that never fires becomes `timedOut` rather than a stuck request.
- Contract: `func markSenderKnown(chat: ChatGUID, saveInContacts: Bool) async throws -> ChatFilterState`
- Route: `POST /api/v2/chat/:guid/known` `{saveInContacts: false}`.
- `saveInContacts: true` writes to the user's address book. Default it to `false` and require
  the client to ask for it.

Read side, shared with §5.2: `ChatFilterState { isFiltered, filterCategory, isKnownSender,
inUnknownSendersFilter, wasDetectedAsSMSSpam }` from `-isFiltered`, `-filterCategory`,
`-cachedIsKnownSender`, `-inUnknownSendersFilter`, `-wasDetectedAsSMSSpam`, served at
`GET /api/v2/chat/:guid/filter`.

---

## 5. Features 4 and 5 — the two that need a spike first

### 5.1 Wallpaper

Build this in four tiers. Each is shippable on its own, and each earlier tier is the fallback
if a later one does not pan out.

**T1 — read (no helper at all). SHIPPED.** `chat.properties` already reaches clients through the v1
serializer, so `backgroundProperties.trabaid` is public. The bytes are one file read:

```
~/Library/Messages/TranscriptBackgroundCache/<trabaid>-watchBackground
  → bplist → backgroundImageData → PNG
```

`GET /api/v2/chat/:guid/background` returns the bytes with a **sniffed** content type — every
background measured is a PNG and serving a JPEG as `image/png` because the one sample was one
is discovered by a client that cannot display it. `GET …/background/info` carries what the
bytes route cannot: `luminance` (what Messages tints its own bubbles by, so a client rendering
a transcript over the image needs it), `isHighKey`, `extensionIdentifier`, and the asset id.

Both live in `TranscriptBackground` + `MediaHandlers.registerBackgrounds`, modelled on
`chat.groupIcon`, and neither requires the helper. Two absences are kept distinct all the way
to the client — "no background set" versus "a background is set and this Mac has not
downloaded it" — because only the second is worth retrying, and the info route reports it as
`available: false` with an identifier rather than as a 404 string.

Verified against this Mac's own database: chat 73's properties blob resolves to asset
`9EB9A5C2-…`, `image/png`, 726,931 bytes, luminance 0.2. Two different chats point at that one
asset, which is why nothing in the reader assumes a conversation owns its background file.

**T2/T3/T4 — setting a background: ABANDONED, and the code is gone.**

Taken to the end of the line against a live Messages and then removed, because a feature that
silently does nothing is worse than an absent one. The full write-up — every wrong assumption
corrected on the way, the exact refusal from PosterBoard, and what would change the answer —
is in `PRIVATE_API_SURFACE.md` §1, which is where anyone looking at this next will start.

The short version: everything IMCore-side is correct and changes nothing, because a transcript
background is rendered by a PosterKit poster registered with PosterBoard, and
`PRSService -createPosterConfigurationForProviderIdentifier:posterDescriptorIdentifier:role:completion:`
answers `Error Domain=PRSService Code=1 "(null)"` for an injected dylib with no UI scene.
ChatKit is not a way around it: it produces the asset correctly (and that part was worth
learning) but has no `@objc` send path of its own.

What remains, and works: reading a background, and asking Messages to download one.

### 5.3 Serving Apple's built-in backgrounds

Asked separately, and the answer is more interesting than expected: **Apple's built-in chat
backgrounds are not images at all.**

```
DynamicBackgroundPosterExtension.appex/Contents/Resources/
    Aurora.vfx  Glitter.vfx  Ocean.vfx  clouds.vfx  default.metallib
GradientBackgroundPosterExtension.appex/Contents/Resources/
    Gradient.vfx  default.metallib
```

Four animated scenes and one parametric gradient, rendered by Metal at display time. There is
no PNG in the bundle to serve, which is why the sync format carries a flattened
`-watchBackground` copy in the first place — even Apple has to render one for devices that
cannot run the scene.

So exposing the gallery means exposing **snapshots**, and those already exist on disk:

```
~/Library/Containers/com.apple.transcriptBackgroundPoster.DynamicExtension/Data/tmp/snapshots/
    f40c5aa0…-1728-1117-16.0-0.0.heic     187 KB
    f40c5aa0…-865-1010-16.0-0.0.heic       92 KB
    …27 files on this Mac, HEIC, <hash>-<width>-<height>-<scale>-<?>.heic
~/Library/Containers/com.apple.transcriptBackgroundPoster.GradientExtension/Data/…  13 files
```

Two tiers, same shape as everything else here:

1. **Serve the cached snapshots.** No injection, no helper — read the two containers, parse
   the filename for dimensions, serve the largest per hash. The catch is in the path: `tmp`.
   These are a cache PosterBoard fills as the user browses the gallery, so the set is
   whatever this Mac happens to have rendered, at whatever sizes its UI asked for, and it can
   be emptied at any time. Fine for "show me what's available"; not something to build a
   client's gallery contract on.
2. **Ask for them.** `CKBackgroundGalleryFetchRequest` +
   `-[CKTranscriptBackgroundChannelController fetchPosterGalleryForChatGUID:deviceIndependentID:backgroundGUID:fetchRequest:completion:]`
   enumerates the gallery properly, and
   `-[PRSService refreshSnapshotForGalleryItemsMatchingDescriptorIdentifier:extensionIdentifier:completion:]`
   renders a snapshot on demand. Both are helper calls, and the second is the one that makes
   the answer complete rather than opportunistic.

The animated ones stay animated only inside Messages: a client gets a still. Handing a client
the `.vfx` scene and a `metallib` is theoretically possible and is not a product.

Worth doing **after** setting a background works. A gallery a client can browse but not apply
is a worse feature than no gallery.

## 6. Spikes, in order, before writing feature code

Each is bounded and each answers a question that changes the code that follows.

### 6.1 Mute-forever sentinel — DONE

Answered by disassembly rather than by the UI, which is both faster and more conclusive:

```bash
cd swift/Tools/private-api
./trace.sh --host Messages --consts IMMutedChatList mutedChatList
./trace.sh --host Messages IMMutedChatList muteChatWithMuteIdentifiers:untilDate:syncToPairedDevice:
./trace.sh --host Messages IMMutedChatList isMutedChatForMuteIdentifiers:
```

Findings are in §0: the defaults domain is `com.apple.MobileSMS.CKDNDList` / `CKDNDListKey`,
values are UNIX epoch seconds, indefinite is `[NSDate distantFuture]` and **not** `nil`, and
`isMuted` is a comparison against now, so timed mutes expire by themselves.

One residual, cheap to close when the write lands: whether `muteChatWithMuteIdentifiers:` has a
nil guard ahead of the `timeIntervalSince1970` call that the call-site walk does not show. It
does not change the implementation — indefinite is written as `distantFuture` either way — so
confirm it by muting a scratch chat with a nil date once and reading the plist, rather than
by blocking on it.

### 6.2 Poster construction — time-boxed to a day

```bash
cd swift/Tools/private-api
./trace.sh --host Messages --limit 900 \
    PRSExternalSystemService createLockScreenPhotosPosterWithImageAtURL:selectLockScreenPoster:completion:
./probe.sh --host Messages members PRUISPosterConfigurationBuilder PRSPosterArchiver
```

Then a throwaway dylib under `Tools/` — the pattern `Tools/observation-probe` already
establishes — injected into Messages, that tries the T4 chain against the **gradient** provider
first and logs each step. Ship whatever tier survives.

### 6.3 Spam argument and filter enum — half a day

```bash
./trace.sh --host Messages IMChatRegistry _chat_markAsSpam:queryID:autoReport:isJunkReportedToCarrier:reportReason:
sqlite3 ~/Library/Messages/chat.db \
  "select is_filtered, count(*) from chat group by is_filtered;"
```

Cross-reference against what the Messages sidebar shows for those conversations.

---

## 7. Testing against a real conversation

Target: `bluebubblesapp@gmail.com`, GUID `any;-;bluebubblesapp@gmail.com`.

**The spam and junk routes are never pointed at that address.** Reporting it would flag a real
Apple ID the project uses, and the reclassification syncs to every device on the account. Test
those two against a conversation created for the purpose and deleted afterwards, or with the
`dryRun` flag below.

Setup, per CONTRIBUTING:

```bash
swift build --arch arm64e --product BlueBubblesHelper
swift run bluebubbles-server --headless \
    --set enable_private_api=true \
    --set additive_endpoints=true \
    --set private_api_helper_path="$PWD/.build/arm64e-apple-macosx/debug/libBlueBubblesHelper.dylib"
```

```bash
BB="http://localhost:1234/api/v2/chat/any%3B-%3Bbluebubblesapp%40gmail.com"
P="password=…"

# Mute, granularly
curl -s -X POST "$BB/mute?$P" -d '{"durationSeconds": 3600}'
curl -s "$BB/mute?$P"                       # expect isMuted, mutedUntil ≈ now+1h
plutil -p ~/Library/Preferences/com.apple.MobileSMS.CKDNDList.plist   # the receipt
curl -s -X DELETE "$BB/mute?$P"

# Background: read what is there, then set one
curl -s "$BB/background?$P" -o /tmp/current.png; file /tmp/current.png
curl -s -X POST "$BB/background?$P" -d '{"filePath": "'"$HOME"'/Downloads/wallpaper.webp"}'
# Verify in Messages' own window, and on the iPhone — a background that does not sync is a
# background that was written locally and never sent.
curl -s -X DELETE "$BB/background?$P"

# Mark known (safe — it only accepts an unknown sender)
curl -s -X POST "$BB/known?$P" -d '{"saveInContacts": false}'
curl -s "$BB/filter?$P"

# Clear history — LAST, and against a scratch chat first
curl -s -X DELETE "$BB/messages?$P" -d '{"confirm": true}'
```

A `dryRun: true` on the spam and filter routes, reporting what *would* be reported
(`-allMessagesToReportAsSpam`'s count, the current `filterCategory`) without calling the
mutating selector, makes those two testable on any conversation. Worth building; it is four
lines and it is the difference between a testable feature and an untested one.

Automated coverage, alongside:

- `Tests/HelperTests/IMCoreSelectorTests.swift` — every new selector pinned.
- `Tests/BBPrivateAPITests/HelperRoundTripTests.swift` — each new action recognised by the
  helper (the `findMyActionsAreKnown` pattern), and each rejected by name when a required field
  is missing.
- `Tests/CompositionTests` — the new group appears only when `additiveEndpoints` is on.
- Parity: `swift test --filter Parity` must stay green, which it will as long as §1.2's first
  rule is honoured.

---

## 8. Order of work

| Step | Depends on | Ships |
|---|---|---|
| ~~1. `BBInvoke` scalar returns (§1.1)~~ **DONE** | — | nothing user-visible |
| ~~2. `GET …/background` (T1)~~ **DONE** | — | reading a chat's wallpaper |
| ~~3. Mute (§2)~~ **DONE, verified live** | 1 | mute/unmute/read |
| ~~4. Clear history (§3)~~ **DONE, guard verified; not executed** | 1 | clear |
| ~~5. Mark known + `GET …/filter` (§4)~~ **DONE, read verified live** | 1 | accept unknown sender |
| ~~6. Spam group (§5.2)~~ **DONE, dry run verified live** | 1, 5 | spam/junk/filter moves |
| 7. Background download (`POST …/background/fetch`) **DONE** | 2 | fetch an asset this Mac lacks |
| ~~8. Background T2/T3/T4~~ **ABANDONED, code removed** (§5.1) | — | — |
| 9. Built-in gallery (§5.3) | — | browse Apple's backgrounds |

Steps 2–6 are all small and independent; step 8 is the one with real risk and it is
deliberately last, behind a feature that is already useful without it.
