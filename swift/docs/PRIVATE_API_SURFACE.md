# Private API expansion surface

Three surveys, in one document because they share a method and a set of constraints:

- **Part I — Messages.app**: what IMCore/ChatKit expose **per conversation**, beyond the
  display name, group icon and focus status the port already ships.
- **Part II — FindMy.app and Notes.app**: what a *new* helper, injected into a *new* host
  app, would reach. Spoiler, and the reason Part II is worth reading before writing any
  code: for FindMy the answer is **AirTags and nothing else**. Everything else is either
  already reachable from Messages or reachable from neither host.

Everything below was read from the runtime on
**macOS 26.5.2 (25F84, arm64e)** — selectors from `class_copyMethodList`, call sites from
in-process disassembly, storage from `chat.properties` in a live `chat.db`. Where something
is inferred rather than measured it says so.

## Part I — Messages.app

## 0. Read this first: Messages.app is a Catalyst app now

```
$ otool -L /System/Applications/Messages.app/Contents/MacOS/Messages
    /System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework/…/ChatKit
    /System/iOSSupport/System/Library/PrivateFrameworks/IMCore.framework/…/IMCore
```

Two consequences, both of which change how the existing tooling should be used.

**ChatKit is in Messages.app's address space.** There is no `ChatKit.framework` under
`/System/Library/PrivateFrameworks` — it exists only under `/System/iOSSupport`, and the
question "is ChatKit reachable?" has the same shape as the `IMFMFSession` question in
`headers/README.md`: it looks absent to a naive check and is not. The injected helper is a
plain-macOS dylib, which dyld happily loads into a Catalyst process, and once inside, every
ChatKit class answers `NSClassFromString`. No `dlopen` needed.

**`Tools/private-api/dump-headers.sh` was dumping the wrong IMCore** — now fixed; it builds both a
macOS and a Catalyst dumper and picks one per host app. It used to build `dump-headers` for
macOS only, so `NSClassFromString("IMChat")` resolved against
`/System/Library/PrivateFrameworks/IMCore.framework` — the *macOS* variant. Messages runs
the *iOSSupport* variant. They are not the same binary:

```
IMChat   macOS 932 instance methods   iOSSupport 936
  only in macOS build:      -dateCreated  -dateModified  -chatItemsForMessages:
                            -setOverallChatStatus:
  only in iOSSupport build: -momentShareCache  -momentSharePresentationCache
                            -subscriptionSwitchParticipantAddChatItem  (+5 more)
```

`-dateCreated` and `-dateModified` are the sharp edge: they are in the checked-in headers'
provenance and **do not exist in the IMCore the helper actually talks to**. This is the exact
failure mode the README was written to prevent, one level deeper.

One mechanism detail, because it is the opposite of what you would guess: **the platform of
the dumper process selects the copy, not the path you ask for.** A Catalyst process that
dlopens `/System/Library/PrivateFrameworks/IMCore.framework/IMCore` is redirected to the
iOSSupport one; a macOS process cannot open the iOSSupport path at all. You cannot get both
into one process, and you cannot pick the wrong copy from the right build. So the fix is a
build flag — and the `// Image:` line every emitted header carries is the receipt:

```bash
clang -target arm64-apple-ios17.0-macabi -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
      -fobjc-arc -framework Foundation -o dump-headers dump-headers.m

BB_DUMP_FRAMEWORKS="/System/iOSSupport/System/Library/PrivateFrameworks/IMCore.framework/IMCore:/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework/ChatKit:/System/iOSSupport/System/Library/PrivateFrameworks/IMSharedUtilities.framework/IMSharedUtilities" \
  ./dump-headers "$output" IMChat IMChatRegistry IMChatInfo IMMutedChatList …
```

TelephonyUtilities has no iOSSupport variant, so the FaceTime classes read the same either
way; `dump.sh` builds them with the Catalyst dumper regardless, to match the host.

§10 has the full inventory as it now stands.

---

## 1. Chat background ("wallpaper") — the one you asked about

It exists, it is in **IMCore, not ChatKit**, and it is a real synced feature: setting it
sends the background to everyone in the chat.

### Reading it — no Private API required at all

`chat.properties` in `chat.db` carries the whole record. Measured, from a real chat:

```
backgroundChannelGUID = "9EB9A5C2-03A3-4843-B03A-C22DE7A99A1C"
backgroundProperties  = {
    trabaid         = "9EB9A5C2-…"      // asset id; also the on-disk filename
    trabav          = 801950158326835840 // version
    trabafs         = 733360             // file size
    trabapv         = 733360
    trabak          = "AKyaDPZ…"         // decryption key
    trabar          = "https://p105-content.icloud…"  // MMCS locator
    trabas          = "gSIdCb2Y4/g9…"    // signature
    traboid         = "…C01USN00"        // owner id
    trabaCommSafety = 0
    refreshDate     = 2026-06-19T16:30:50Z
}
```

The bytes live in `~/Library/Messages/TranscriptBackgroundCache/<trabaid>`, confirmed by
calling `IMTranscriptBackgroundDirectory()`, which returns
`file:///Users/<me>/Library/Messages/TranscriptBackgroundCache/`. Two files per background:

| File | Format |
|---|---|
| `<trabaid>` | **Apple Archive** (`AA01` magic) — a Poster archive, same family as Contact Posters / Lock Screen |
| `<trabaid>-watchBackground` | binary plist: `backgroundImageData` (**a plain PNG**), `extensionIdentifier`, `isHighKey`, `luminance` |

**That second file is the shortcut.** Serving a conversation's background to clients is
"read the bplist, hand back `backgroundImageData`" — no Poster decoding, no injection, no
helper round-trip. It parallels `chat.groupIcon` almost exactly.

IMCore's own getters agree, if you would rather go through the helper:

```objc
- (id)transcriptBackgroundDetails;      // the dict above
- (id)transcriptBackgroundGUID;         // details["trabaid"]
- (id)transcriptBackgroundPath;         // IMTranscriptBackgroundDirectory() + trabaid
- (id)transcriptBackgroundVersion;
- (long long)transcriptBackgroundCommSafetyState;
- (bool)_supportsTranscriptBackgrounds; // false for left/read-only/business/Mako/Apple/Stewie chats
```

### Writing it

```objc
- (void)setTranscriptBackgroundAndSendToChat:(id)background transferID:(id)transferID;
```

Disassembling `-[IMChatRegistry _chat:setTranscriptBackgroundAndSendToChat:transferID:]`
resolves the whole path:

```
[NSURL URLWithString:background]            ← arg 1 is a URL *string*, not an object
[remoteDaemon setTranscriptBackgroundAndSendToChat:<url>
                                          toChatID:<chat identifier>
                                        identifier:<chat guid>
                                             style:<chatStyle>
                                        transferID:<arg 2>
                                           account:<account.uniqueID>
                                        completion:<block>]
```

So the call is: **a file URL string plus an `IMFileTransfer` GUID**, and imagentupload-and-
sends it. The transfer GUID comes from machinery the port already has —
`FileTransfer.register(path:)` in `IMCoreObjects.swift:389` already does
`guidForNewOutgoingTransferWithLocalURL:` for attachments and group icons.

Also present, and worth wiring for robustness since Apple calls them itself:

```objc
- (void)refetchLocalTranscriptBackgroundAssetIfNecessary;   // inbound: fetch a peer's background
- (void)retryTranscriptBackgroundUploadIfNecessary;          // outbound: retry a failed upload
```

### Writing it does not work, and this is how far it got

**Reading a background works and ships. Setting one does not, and the blocker is structural.**
This was taken to the end of the line on macOS 26.5.2 with the helper injected into a live
Messages; the code was then removed, because a feature that silently does nothing is worse
than an absent one. What follows is the receipt, so nobody re-runs it.

**Everything on the IMCore side is correct and it changes nothing.** Measured, per attempt:
the transfer registers with `existsAtLocalPath = 1` and real `totalBytes`; the conversation
answers `_supportsTranscriptBackgrounds = true`; the setter is invoked without raising; and
`chat.properties` never gains a `backgroundProperties` key, on that Mac or any other device.
No error, anywhere.

Four things were established on the way, each of which corrected a wrong assumption:

1. **A background is TWO files, paired by path.** `-[NSURL im_associatedWatchBackgroundURL]`
   (IMSharedUtilities) appends `-watchBackground` to the last path component and looks in the
   same directory. So the poster archive and its watch image must sit together under their own
   names — staging them into separate directories, or renaming either, breaks the pair
   silently.
2. **Registering an `IMFileTransfer` MOVES the file** into
   `<container>/Library/Messages/Attachments/xx/yy/<guid>/`, orphaning anything staged beside
   it.
3. **The watch image is RENDERED, not copied, and ChatKit renders it.**
   `-[CKTranscriptBackground createBackgroundWithWatchDataWithCompletion:]` hands back a *new*
   background object carrying `watchData` — 737,621 bytes from a 3,017-byte poster on this
   machine, against the 733,360 (`trabafs`) a real synced background reports. Re-sending a
   poster archive on its own was never the payload.
4. **`~/Library/Messages/TranscriptBackgroundCache` is writable from inside the helper**, and
   the pair can be written there under a fresh UUID. The apparent container redirection —
   `<container>/Library/Messages` holds only `Attachments` — is IMCore's own attachment-path
   logic, not the sandbox.

**Why it still fails: PosterBoard will not mint a poster for a headless caller.** A transcript
background is rendered by a PosterKit poster registered with PosterBoard, and the conversation
holds it in a channel. The channel is not the missing piece — this Mac's test conversation
already had one, created months earlier — but its `posterConfigurationIdentity` is **nil**,
and every route to filling that in refuses:

```
PRUISPosterConfigurationBuilder(provider:role: PRPosterRoleBackdrop)
    -buildPosterConfigurationWithCompletion:      → completes in 0.6s with nothing at all
PRSService -createPosterConfigurationForProviderIdentifier:posterDescriptorIdentifier:role:completion:
    ("…DynamicExtension", "hero", "PRPosterRoleBackdrop")
                                                 → Error Domain=PRSService Code=1 "(null)"
CKTranscriptBackgroundChannelController
    -updateChannelUsingChatGUID:…posterConfiguration:completion:
                                                 → fails: the coordinator sends `_path` to
                                                   what it was given, i.e. it wants a real
                                                   PFPosterContents
```

`PRUIS` is **PosterBoardUIServices**, and that is the likeliest reading of the refusal:
creating a poster is a UI operation that instantiates the poster extension, and an injected
dylib driving Messages through a socket has no scene for it. `PRSService Code=1` with a null
message is posterboardd declining; it is not a missing selector, an entitlement we could name,
or an argument we got wrong.

**The daemon cannot be asked what went wrong.** `-[IMChat setTranscriptBackgroundAndSendToChat:transferID:]`
forwards to `-[IMChatRegistry _chat:…]`, which calls the daemon's
`setTranscriptBackgroundAndSendToChat:toChatID:identifier:style:transferID:account:completion:`
**and discards the completion**. Calling that selector directly — the signature is declared in
`IMDaemonProtocol` as `v68@0:8@16@24@32C40@44@52@?60` — is accepted by the `remoteDaemon`
proxy, and the completion never fires: a reply block does not survive that forwarding
boundary. `imagent` logs nothing reachable through `log show`. There is no error to read from
inside Messages, by construction.

Two smaller findings worth keeping. `IMCopyGUIDForChatOnAccount` — which the registry uses
instead of reading `chat.guid` — returns the same `any;-;…` placeholder-service GUID for a
one-to-one chat, so the GUID was never the problem. And ChatKit is **not** an alternative send
path: `-[CKConversation setPendingTranscriptBackground:transferID:]` only posts an
`NSNotification` and `-setTranscriptBackground:` sets a property; the code that sends is
Swift-internal with no `@objc` entry point. ChatKit's role here is producing the asset, which
it does correctly.

**What would change the answer**: a way to obtain a `PRSPosterConfiguration` without a UI
context. Everything downstream of that is already known to work.

### What ships instead

1. **Read + serve** the current background, via the `-watchBackground` PNG. No Private API at
   all, and `luminance` comes with it — which is what a client tinting its own transcript
   needs.
2. **Download** a background this Mac does not have yet:
   `-refetchLocalTranscriptBackgroundAssetIfNecessary` → the daemon's
   `refetchChatBackgroundIfNeededForChatIdentifier:style:account:`. Fire and forget; the file
   appearing in the cache is the only completion there is.

Apple's built-in backgrounds are worth a note of their own: they are not images. The two
extensions ship `Aurora.vfx`, `Glitter.vfx`, `Ocean.vfx`, `clouds.vfx` and `Gradient.vfx` with
a `default.metallib` — Metal scenes rendered at display time, which is *why* the sync format
carries a flattened watch copy. Serving them to clients means serving snapshots, and
PosterBoard already caches those per extension under
`~/Library/Containers/com.apple.transcriptBackgroundPoster.*/Data/tmp/snapshots/<hash>-<w>-<h>-<scale>-*.heic`.

Event: `__kIMChatTranscriptBackgroundChangedNotification` (rung 1).

---

## 2. Mute / Do Not Disturb — the biggest easy win

Not implemented today, and clients ask for it constantly.

```objc
// IMChat
- (bool)isMuted;                    → [IMMutedChatList.sharedList isMutedChat:self]
- (id)muteUntilDate;
- (void)setMuteUntilDate:(id)date;  → [IMMutedChatList.sharedList muteChat:self untilDate:date]
```

`IMMutedChatList` (IMSharedUtilities) is the real store:

```objc
- (void)muteChat:(id)chat untilDate:(id)date syncToPairedDevice:(bool)sync;
- (void)muteChatWithMuteIdentifiers:(id)ids untilDate:(id)date syncToPairedDevice:(bool)sync;
- (void)unmuteChatWithMuteIdentifiers:(id)ids syncToPairedDevice:(bool)sync;
- (id)unmuteDateForChat:(id)chat;
- (bool)isMutedChat:(id)chat;
- (id)mutedChatList;
```

`nil` date reads as mute-indefinitely — **this inference was WRONG, and it is corrected in
`CHAT_CONTROLS_PLAN.md` §0**. Measured since: the write stores
`[untilDate timeIntervalSince1970]`, so a nil date stores `0.0`, and the read compares that
against `[NSDate date]` — i.e. a nil mute reads back as NOT muted. Indefinite is
`[NSDate distantFuture]`, which is the `64092211200` that appears in
`~/Library/Preferences/com.apple.MobileSMS.CKDNDList.plist` (`com.apple.MobileSMS.CKDNDList` /
`CKDNDListKey` is the store, confirmed from both the read and write call sites). `syncToPairedDevice:` maps to whether the change propagates
to the iPhone — expose it, don't hardcode it. The legacy per-chat `ignoreAlertsFlag` key still
appears in `chat.properties` on 6 chats here, so old state is readable server-side too.

Event: `__kIMMutedChatListDidChangeNotification`.

Shape: `POST/DELETE /chat/:guid/mute`, `GET /chat/:guid/mute` — pairs naturally with the
existing pinning group.

---

## 3. Everything else on IMChat, ranked

### Worth building

| Feature | Selector(s) | Notes |
|---|---|---|
| **Per-chat read receipts** | `-userToggledReadReceiptSwitch:(bool)`, `-supportsSendingReadReceipts` | Persisted as a chat property; the version key is `EnableReadReceiptForChatVersionID`. Per-conversation override of the global setting. |
| **Auto-translate** | `-setAutomaticallyTranslate:languageCode:userLanguageCode:`, `-isAutomaticTranslationEnabled`, `-translationLanguageCode`, `-supportsAutomaticTranslation`, `-checkTranslationLanguageStatusForLanguageCode:` | macOS 26 feature, no client exposes it. Event: `__kIMChatAutomaticTranslationChangedNotification`. |
| **Spam / junk / filtering** | `-markAsSpam:`, `-markAsSpam:isJunkReportedToCarrier:`, `-reportJunk`, `-reportJunkToCarrierViaRelay:`, `-recoverFromJunkTo:`, `-updateIsFiltered:`, `-isFiltered`, `-filterCategory`, `-inUnknownSendersFilter` | Moves a chat between Unknown Senders / Junk / Transactions / Promotions and back. Event: `__kIMChatIsFilteredChangedNotification`. |
| **Mark sender known** | `-markAsKnownAndSaveInContacts:completion:` | Calls `updateIsFiltered:` + `_chat_acceptChat:` + `markChatsAsReviewed:`. The "accept this unknown sender" action. |
| **Recently Deleted** | `-recoverableMessagesCount`, `-unreadRecoverableMessagesCount`, `-earliestRecoverableMessageDeletionDate`, `-latestRecoverableMessageDeletionDate` | Events: `__kIMChatRegistryDidMoveMessagesInChatsToRecentlyDeletedNotification`, `…DidRecoverMessagesInChatsNotification`, `…DidPermanentlyDeleteRecoverableMessagesInChatsNotification`. Recovery itself is on `IMChatRegistry`. |
| **Clear history** | `-deleteAllHistory` | Destructive — gate it. Event: `__kIMChatHistoryClearedNotification`. |
| **Invitations / join state** | `-acceptInvitation`, `-declineInvitation`, `-join`, `-joinState`, `-hasUnhandledInvitation` | Event: `__kIMChatJoinStateDidChangeNotification`. |
| **Send current location** | `-sendCurrentLocationMessage` | One selector, no arguments. Notable given `headers/README.md` correctly establishes there is no way to *set* your location — this sends the real one, which is a different and permitted thing. |
| **Business unsubscribe** | `-unsubscribe`, `-canUnsubscribe`, `-unsubscribeText` | Builds an `IMMessage` from `unsubscribeText` and sends it. Narrow, but trivial. |
| **Arbitrary chat properties** | `-valueForChatProperty:`, `-setValue:forChatProperty:` (→ `IMChatRegistry _chat:setValue:forChatProperty:`) | The escape hatch every feature above funnels through. A generic get/set is tempting; it is also how you corrupt a chat. Prefer typed endpoints. |

### Readable server-side, no helper needed

`chat.properties` also carries `chatSummaryDictionary` (`chatSummary` blob,
`chatSummaryAssociatedMessage`, `chatSummaryConsumed`) — **Apple Intelligence conversation
summaries**, already on disk. Event: `__kIMChatRegistryDidUpdateMessagesWithSummaryNotification`.
Other keys seen in the wild: `lastSeenMessageGuid`, `markedAsKnownDate`, `shouldForceToSMS`,
`hasBeenAutoSpamReported`, `wasDetectedAsSMSSpam`, `groupPhotoGuid`, `LegacyGroupIdentifiers`.

### Message-level, not chat-level, but adjacent and high value

**Scheduled messages ("Send Later").** `IMMessage` carries `scheduleType` / `scheduleState`
through its designated initialiser
(`initWithSender:time:text:…threadIdentifier:scheduleType:scheduleState:`), and `IMChat` has
the full lifecycle: `editScheduledMessageItem:scheduleType:deliveryTime:`,
`editScheduledMessageItems:scheduleType:deliveryTime:`,
`cancelScheduledMessageWithGUID:destinations:cancelType:`,
`retractScheduledMessagePartIndexes:fromChatItem:`, `hasCancellableScheduledMessage`. This is
probably the single most requested thing in this whole list and it does not appear to be
blocked by anything.

### Tapbacks, including emoji — `IMTapbackSender`

Backs `message.react`. Disassembled from `-[IMChat(CKMessageAcknowledgment)
sendTapback:forChatItem:languageIdentifier:]` on macOS 26.5.2, which is what Messages calls
for every tapback:

| Step | Selector | Notes |
|---|---|---|
| tapback | `+[IMTapback tapbackWithAssociatedMessageType:]` | the six named ones |
| tapback (emoji) | `-[IMEmojiTapback initWithEmoji:isRemoved:]` | types 2006 / 3006, emoji in `associatedMessageEmoji` |
| part | `IMChatHistoryController` → `_newChatItems[partIndex]` | as replies and stickers |
| send | `-[IMTapbackSender initWithTapback:chat:messagePartChatItem:]`, then `send` | a Swift class in IMCore; the three-argument initializer derives the GUID (`p:<part>/<guid>`), the part's range, the summary via `+[IMChat configureMessageSummaryInfoForChatItem:]` and the thread identifier itself. `send` answers the tapback's `IMMessage` |

Verified: love, 🔥 and −🔥 all land with `p:0/<guid>` and the part's range `0:55`; the
emoji rows carry `associated_message_emoji`. Messages replaces a prior reaction of yours
when a new one is sent and deletes the row when one is removed.

The association-initializer path (bare GUID, range `(part, 1)`, text `TEMP`) is kept only
as the fallback for a macOS without `IMTapbackSender`, and cannot carry an emoji.

### Polls — an app balloon, not a message type

Built: `message.poll`, `message.createPoll`, `message.votePoll`. The mechanism, the payload
format, the message thread and the routes are in [`docs/POLLS.md`](POLLS.md), which is the
reference for this. In short: a poll is an
iMessage app message from `com.apple.messages.Polls` whose `payload_data` archive carries a
`data:` URL of JSON; a vote is a custom acknowledgement (`associated_message_type` 4000) built
by `+[IMMessage customAcknowledgementMessageWithPayloadData:associatedMessageGUID:balloonBundleID:messageSummaryInfo:threadIdentifier:]`.
macOS 26 only (`-[IMChat _supportsPolls]`).

### Deleting a message locally — `deleteIMMessageItems:`, not `deleteChatItems:`

Backs `chat.deleteMessage` (`DELETE /chat/:guid/:messageGuid`). Measured on 26.5.2: the helper
had called `-[IMChat deleteChatItems:]` with the chat items off a freshly loaded message item,
and three deletes answered 200 while all three rows stayed in `chat.db`. Those items are not
the transcript's own, so the chat has nothing to match them against — the same "success that
does nothing" the reference's `CKChatController deleteChatItem:` produces headless.
`-[IMChat deleteIMMessageItems:]` takes the message ITEM itself and deletes the row; it is
used first, with the chat-item form kept as the fallback for a release without it.

### Send Later — the date goes on the COMPOSITION

High-level write-up and the REST surface: [`docs/SEND_LATER.md`](SEND_LATER.md).

Backs `message.sendLater` / `message.cancelScheduled`. Measured on macOS 26.5.2.

**The obvious approach does not work.** `IMMessage` has `scheduleType` and `scheduleState`, and
an initializer that takes both (`initWithSender:time:…threadIdentifier:scheduleType:scheduleState:`).
Building a message that way with type 2 / state 1 and sending it through `-[IMChat sendMessage:]`
sends it IMMEDIATELY: the row lands `schedule_type 0`, `is_delivered 1`, delivered now. Whatever
files a message as scheduled is not those two words on the message object.

What Messages does, from `-[CKComposition(IMSuperFormat) messageWithGUID:superFormatText:…]`:

| Step | Selector |
|---|---|
| date | `-[CKSendLaterPluginInfo initWithSelectedDate:]` |
| attach | `-[CKComposition setSendLaterPluginInfo:]` |
| build | `-[CKConversation messagesFromComposition:]` — reads `sendLaterPluginInfo.selectedDate`, passes it as the message's `time:` with `scheduleType 2` / `scheduleState 1`; with no info it passes `[NSDate date]` and 0 / 0 |
| send | `-[CKConversation sendMessage:newComposition:]` |

Verified: the row lands `schedule_type 2`, `schedule_state 2` (state moves 1 → 2 once the daemon
takes it), `is_delivered 0`, and `date` = the delivery instant, 15 minutes out.

**Rescheduling and "send now" are one selector**, `-[IMChat editScheduledMessageItem:scheduleType:deliveryTime:]`
(plural variant as the fallback — the transcript uses it because a scheduled section can hold
several messages due together). Reschedule passes type 2 and the new date; send now passes
type **0 and a nil date**, which are the values `-[CKScheduledSectionDateCell handleSendNowAction:]`
forwards and the branch IMCore logs as "Modifying scheduled time to be immediate". Measured:
a message at 08:09 moved to 08:54, then send-now delivered it at once and the row dropped to
`schedule_type 0`, `schedule_state 0`, `is_delivered 1`.

**Editing a scheduled message's text** is `-[IMChat editScheduledMessageItem:atPartIndex:withNewPartText:newPartTranslation:]`
(translation nil), which rewrites the pending item in place — no edit history, because nothing
has been delivered.

**Cancelling takes the message ITEM.** `-[IMChat cancelScheduledMessageWithGUID:destinations:cancelType:]`
with nil destinations returns without raising and changes nothing — measured, the row stayed
scheduled. `-[IMChat cancelScheduledMessageItem:cancelType:]` with cancel type 1 works, and the
row is deleted from `chat.db` outright.

### Reply threads — `threadIdentifier` is not a GUID

Backs `selectedMessageGuid` on `message.sendText`, `message.sendMultipart` and
`message.sendAttachment`. Measured 2 September 2026 on macOS 26.5.2 after every reply the
helper sent landed with an empty `thread_originator_guid`.

`IMMessage.threadIdentifier` names a THREAD, and IMCore formats one as
`r:<part index>:<range location>:<range length>:<originator guid>` (`IMCreateThreadIdentifier`,
disassembled). imagent parses it back with `IMMessageThreadIdentifierGetComponents` into
chat.db's `thread_originator_guid` and `thread_originator_part` (`0:0:55`). A bare message
GUID fails that parse: the message sends, is delivered, and is not a reply — no error at any
layer. The helper had passed the bare GUID on both send paths.

What Messages and the Objective-C helper do, now `IMThreads` in the Swift helper:

| Step | Selector | Notes |
|---|---|---|
| target | `IMChatHistoryController loadMessageWithGUID:` → `_imMessageItem` → `_newChatItems[partIndex]` | the `IMMessagePartChatItem` being replied to |
| join | `-[IMMessagePartChatItem threadIdentifier]`, `threadOriginator` | non-empty when the target is already in a thread; reuse it so a reply to a reply lands under the original message |
| create | `IMCreateThreadIdentifierForMessagePartChatItem(part)` | exported C function in IMCore. **Returns +0** (ends in `objc_autoreleaseReturnValue`; the name is not the CF Create rule) — taking it retained freed a string Messages still held and TextInput crashed on it later. Reads the part's `index`, `messagePartRange` and message GUID |
| set | `-[IMMessage setThreadIdentifier:]`, `setThreadOriginator:` | on the built message, before `sendMessage:` / `sendMessage:newComposition:` |

Verified on 26.5.2: text, multipart and attachment replies all land with the target's GUID
and `0:0:<length>`, and a reply to one of them carries the same originator.

**Used on every macOS, not gated.** This is the Objective-C helper's own reply code
(`Messages/MacOS-11+/BlueBubblesHelper/BlueBubblesHelper.m:1106`, from "Support sending
replies on big sur and up", October 2021), which shipped on Big Sur through Ventura and
works on Tahoe. The port had passed the bare message GUID instead; no release is known to
accept that, and a check on a Sequoia machine is only owed to the resolved form.

One hazard, recorded because it cost a Messages crash: the originator comes back from an
accessor at +0 and dies when the autorelease pool drains, which a Swift `await` does. Resolve
the thread inside the same synchronous block as the send, never across a suspension.

### Stickers — `message.sendSticker`

> Reading and adding to the sticker **library** — the picker's contents, which live in a
> separate Core Data store and mostly need no helper at all — is a different surface, and
> `docs/STICKER_LIBRARY.md` covers it. This section is about SENDING one onto a message.

Backs `POST /api/v2/message/sticker` and the wire action `send-sticker`. Measured on macOS
26.5.2 by disassembling Messages' own drag-and-drop send (`Tools/private-api` resolves the
IMPs; `lldb` on a throwaway Catalyst process that `dlopen`s ChatKit gives symbolised output —
never attach to the user's Messages for this).

**What a sticker is.** An ASSOCIATED message, like a tapback, whose payload is a file
transfer. On the row: `associated_message_type = 1000`, `associated_message_guid =
p:<part>/<target guid>`, `associated_message_range_{location,length}` = the parent PART's
range in the message text (so `length` is the part's character count, not 1),
`message_summary_info = {amc: 0, ust: true}`, text `U+FFFC`. On the attachment row:
`is_sticker = 1`, `sticker_user_info` (a bplist with the geometry below), `attribution_info`
(`{bundle-id, name: "Stickers", accessl}`). An emoji sticker is type 1001. A sticker sent AS A TAPBACK
("react with a sticker") is `IMStickerTapback`, types 2007 / 3007 — built, see below.

**The chain Messages runs**, from `-[CKChatController(CKChatController_Stickers)
sendSticker:withDragTarget:draggedSticker:]` down:

| Step | Selector | Notes |
|---|---|---|
| model | `-[IMSticker initWithStickerID:stickerPackID:fileURL:accessibilityLabel:accessibilityName:moodCategory:stickerName:]` | `IMSharedUtilities`. `stickerPackID` for a user-made sticker is `com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.Stickers.UserGenerated.MessagesExtension`; the same string goes in `setBallonBundleID:` (sic) for attribution |
| geometry | `+[IMSticker userInfoDictionaryWithLayoutIntent:parentPreviewWidth:xScalar:yScalar:scale:rotation:initialFrameIndex:stickerPositionVersion:externalURI:]` | writes `sli spw sxs sys ssa sro safi spv suri`. Layout intent, frame index and position version are 0 for a dropped sticker |
| media | `-[CKMediaObjectManager mediaObjectWithSticker:stickerUserInfo:]` | copies the file into ChatKit's staging dir (MD5-named), adds `sid`/`pid`/`shash`/`sir` to the user info, resolves attribution through `CKBalloonPluginManager balloonPluginForBundleID:`, then `-[CKIMFileTransfer initWithStickerFileURL:transferUserInfo:attributionInfo:animatedImageCacheURL:adaptiveImageGlyphContentIdentifier:adaptiveImageGlyphContentDescription:]` → `IMFileTransferCenter createNewOutgoingTransferWithLocalFileURL:`, `setIsSticker:YES`, `setStickerUserInfo:`, `setAttributionInfo:`. Logs "Create media object for sticker: %@ OK" |
| composition | `+[CKComposition stickerCompositionWithMediaObjects:]` | = `compositionWithMediaObjects:subject:nil` |
| parent | `-[IMMessagePartChatItem guid]`, `messagePartRange`, `threadIdentifier` | the chat item for the target part, loaded through `IMChatHistoryController` as edit/unsend already do. An aggregate (photo gallery) item is unwrapped to `aggregateChatItems.firstObject` |
| message | `-[IMMessage initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:threadIdentifier:]` | sender nil, time now, text = `-[CKComposition superFormatText:]`, flags **5**, guid `[NSString stringGUID]`, type 1000, range = the part's, summary nil, thread = the part's |
| link | `-[CKIMFileTransfer setIMMessage:]` on `[mediaObject transfer]` | |
| send | `-[CKConversation sendMessage:newComposition:NO]` | NO, where a typed message passes YES |

**Sticker tapbacks** (`tapback: true` on the route) are the same media object and transfer,
handed to `-[IMStickerTapback initWithTransferGUID:isRemoved:]` — which sets 2007, or 3007 when
removed (disassembled) — and sent through `IMTapbackSender` like every other tapback. Messages
positions it, so the geometry is ignored. Measured: the row lands type 2007 with the part's own
range, delivered. Apple's own carry a much smaller `sticker_user_info` (just `pid` and `spv`,
with the plain extension bundle id rather than the balloon-prefixed one) and a summary of
`{amc: 3, cmmAO: 0, cmmS: 0, ust: true}`; ours still carries the placed-sticker geometry, which
did not stop it being accepted.

Gate: `-[IMChat _supportsStickers]` (and `_supportsTapbacks`) — worth checking before
building; SMS conversations say no.

Two hazards the helper handles. `messagePartRange` returns a struct, which the invocation
bridge now boxes as `NSValue` (it returned nil for every struct before). And
`superFormatText:` takes an out-pointer for the transfer GUIDs; the bridge only writes nil
into pointer arguments, so the GUID is read off the media object's `transferGUID` instead.

### UI-only — do not chase

`CKChatController`, `CKConversationListCollectionViewController`, the `CK*BackgroundView`
family, `CKUITheme*`. These render; they hold no state that is not already in IMCore or
`chat.db`. The two ChatKit classes that matter are `CKTranscriptBackground` (poster
construction) and `CKBackgroundGalleryFetchRequest` (Apple's built-in gallery), and both are
about *producing* a background asset, not about the chat.

---

## 3b. Shared contact cards (nicknames) — `icloud.contactCard`

Backs `GET /api/v1/icloud/contact` and the wire action `get-nickname-info`. A "nickname" here
is the **name and photo someone chose to share** through Messages — the Share Name and Photo
feature — and is unrelated to anything in Contacts.

`IMNicknameController` (`sharedInstance`), measured on macOS 26.5.2:

| Selector | Returns | Use |
|---|---|---|
| `personalNickname` | `IMNickname` | The LOCAL user's own card. This is the no-address case, which is the default form of the route |
| `nicknameForHandle:` | `IMNickname` | One handle's card |
| `nicknameForHandleIDs:` / `currentNicknameForHandleIDs:` | dictionary of handle → `IMNickname` | Several at once |
| `imageDataForHandle:` | `NSData` | Avatar bytes directly, bypassing the file path |

`IMNickname` carries `displayName`, `firstName`, `lastName`, `handle`, and `avatar`
(`IMNicknameAvatarImage`, whose `imageFilePath` is the on-disk photo and whose `imageExists`
says whether it has been downloaded yet). Full dump: `docs/headers/macos-26.5.2/IMNickname.h`.

**Two traps, both of which produce a silently empty result rather than an error:**

1. **These selectors return objects, not dictionaries.** An earlier implementation called
   `currentNicknameForHandleIDs:` and then read `entry["name"]` from the result as
   `[String: Any]`. Every field came back nil, so the method reported "no shared nickname"
   for everybody and nothing failed loudly.
2. **`personalNickname` returns nil outside Messages.** The controller needs the IMCore
   daemon connection that exists only inside the host application, so a standalone probe
   cannot verify this path — it returns nil on a machine where Messages is signed in and
   working. Verification requires the injected helper on a SIP-disabled Mac.

The avatar is delivered to the server as a **path**, not as bytes, matching the reference
implementation: the file is on the same Mac, the server already requires Full Disk Access, and
the server base64-encodes it. See `SystemHandlers.contactCardPayload`.

## 4. Suggested order

1. `GET /chat/:guid/background` — read the `-watchBackground` PNG off disk. No injection, no
   risk, immediately useful.
2. Mute/unmute + `isMuted` on chat query responses. One new helper action, one notification.
3. Per-chat read receipts, then auto-translate. Both are single-selector chat properties.
4. Spam/filtering/mark-known as one group — they share `updateIsFiltered:`.
5. Scheduled messages. Bigger, but the plumbing is all on `IMMessage`'s initialiser.
6. ~~Setting a background.~~ **Tried and abandoned — see §1.** Re-applying an existing poster
   archive does not work either: the archive is meaningless without a PosterBoard poster
   behind it, and PosterBoard refuses to mint one for a headless caller.

Before any of 2–6, fix `dump.sh` per §0 and re-dump. Right now every selector in this document
was verified against the correct IMCore by hand, and the next person's will not be.

---

## 5. Reproducing this

Everything in this document came out of `Tools/private-api/`, and every finding below can be
re-derived in one command. Full reference: [`private-api/tools.md`](private-api/tools.md).

```bash
# "Does anything, anywhere, know the word wallpaper?"
./Tools/private-api/probe.sh --host Messages selectors wallpaper background

# What a method actually does — this is what turned two anonymous `id` arguments into
# the documented daemon call in §1.
./Tools/private-api/trace.sh --host Messages \
    IMChat setTranscriptBackgroundAndSendToChat:transferID:

# Where "trabaid" and "backgroundProperties" came from.
./Tools/private-api/trace.sh --host Messages --consts IMChat transcriptBackgroundPath

# Every rung-1 event cited here. 227 names on 26.5.2.
./Tools/private-api/notifications.sh

# The Swift wall in §7, as a single table.
./Tools/private-api/probe.sh --host FindMy members \
    FMIPCore.FMIPManager FMFSession FindMyLocate.Session

# Regenerate docs/headers/macos-<version>/.
./Tools/private-api/dump-headers.sh
```

Two of those deserve a note, because both look like the wrong approach and are not:

- **The tools build themselves for Catalyst.** A native macOS process cannot open anything
  under `/System/iOSSupport`, and silently sees a different copy of the frameworks that ship
  twice — §0. `dump-headers.sh` reads each host app's Mach-O and matches it.
- **The notification scrape greps the dyld shared cache.** These names are `@"__kIM…"`
  string literals in `__cstring`, not exported symbols, so `dlsym` reports them absent —
  a false negative believed more than once in this project's history. Private frameworks
  also have no on-disk binary at all; they exist only in the cache.

For producing a dump on a macOS release other than the one this was written against, see
[`private-api/collecting-headers.md`](private-api/collecting-headers.md).

---
---

# Part II — FindMy.app and Notes.app

Same machine, same method: macOS 26.5.2 (25F84, arm64e), selectors from the runtime, call
sites from disassembly, storage from the live files on disk. Headers for everything named
here are checked in under `docs/headers/macos-26.5.2/` and regenerate with
`Tools/private-api/dump-headers.sh`.

## 6. What a third and fourth helper costs

The port's existing architecture already answers most of this, which is the good news.
`SocketLocation.swift` establishes — from measurement, not assumption — that a sandboxed app
can only `connect` to a Unix socket **inside its own container**, and that the restriction is
symmetric, so there is one socket per host app and each helper connects to the one in its own
container. Adding a host is therefore additive, not a redesign:

```swift
public enum HelperHost {
    public static let messages = "com.apple.MobileSMS"
    public static let faceTime = "com.apple.FaceTime"
    public static let notes    = "com.apple.Notes"     // new
    public static let findMy   = "com.apple.findmy"    // new
}
```

`privateAPISockets` then binds four paths instead of two. Both new paths fit the `sun_path`
budget with room to spare — measured on this account, against `maximumSocketPathLength = 103`:

```
79  ~/Library/Containers/com.apple.MobileSMS/Data/private-api.sock   (existing)
78  ~/Library/Containers/com.apple.FaceTime/Data/private-api.sock    (existing)
75  ~/Library/Containers/com.apple.Notes/Data/private-api.sock
76  ~/Library/Containers/com.apple.findmy/Data/private-api.sock
```

Both apps are sandboxed (`com.apple.security.app-sandbox`) and both containers already exist,
so the server writes the socket where it writes the other two — no new permission beyond the
Full Disk Access it already requires.

Each new dylib also needs its own bootstrap target with a **distinct constructor symbol**,
following `Helper/HelperBootstrapFaceTime/bootstrap.c`: the FaceTime helper exports
`bluebubbles_facetime_helper_main` rather than reusing `bluebubbles_helper_main` precisely so
the dylibs can be linked into one test binary without a duplicate symbol. A `HelperShared`
already exists for the parts that do not vary (`IMCoreRuntime`, `HelperSocketClient`), so a
new helper is a bootstrap, a `*HelperMain`, and a dispatch table.

### The host app has to be running, and that is already how this works

Worth stating plainly because it looks like a new constraint and is not: a helper needs its
host app running, so injecting into Notes or FindMy means those apps run. That is the same
deal Messages and FaceTime already have, and it is normal.

It is not even a special case in the code. `DylibInjector.inject` does not attach to a live
process — it **terminates the app and relaunches it** with `DYLD_INSERT_LIBRARIES` set, then
waits for the helper's `ping`:

```swift
await processRunner.terminate(applicationNamed: target.applicationName)
try await Task.sleep(for: policy.relaunchDelay)
// ... launch(executable:environment:) with the dylib inserted
```

`terminate` returns immediately when nothing matches, so a cold app takes the identical path
as a running one. Cold start was always supported; nobody had exercised it because both
current hosts happen to be running already.

The surrounding machinery is generic too. `PrivateAPIService` keeps `injectors:
[String: DylibInjector]` keyed by bundle identifier, and `injectManagedApp(...)` already takes
the app name, bundle identifier and dylib path as parameters — the comment on it says as much:

> One injector per app. Messages and FaceTime are separate processes with separate dylibs and
> separate sockets, so they inject, fail and retry independently.

FaceTime is already wired as the optional one (`try?`, so its failure cannot take Messages
down). A third or fourth host is a `Target`, a socket path, a dylib, and a config switch —
not new machinery.

Two things still worth doing, neither of them a blocker:

- **Report the state.** A user can quit Notes or FindMy at any time, and the feature goes
  quiet. The port already reports the observation rung per event
  (`OBSERVATION_LADDER.md`); "host app not running" belongs in the same place rather than
  showing up as an endpoint that silently returns nothing.
- **Decide about the Dock.** `NSWorkspaceOpenConfiguration.hides` / `NSRunningApplication.hide()`
  keeps a launched app out of the way, though not out of the Dock. Cosmetic, and it can be
  decided after the feature works.

### Entitlements: much narrower than it first looks

Injected code inherits the host's entitlements — that is the whole basis of the design, so
"what does FindMy.app have that Messages does not" is the question that decides whether a
fourth helper is worth building. Read in full rather than from `headers/README.md`'s partial
list, the answer is **much less than expected**. Messages.app carries *all four* of the
findmylocate services:

```
com.apple.findmy.findmylocate.locationservice     ✓ Messages   ✓ FindMy
com.apple.findmy.findmylocate.friendshipservice   ✓ Messages   ✓ FindMy
com.apple.findmy.findmylocate.fenceservice        ✓ Messages   ✓ FindMy
com.apple.findmy.findmylocate.settings            ✓ Messages   ✓ FindMy
com.apple.icloud.fmfd                             ✓ Messages   ✓ FindMy
```

The split is real and enforced — `findmylocateagent` vends one Mach service per entitlement
and checks it per connection (`FindMyBase.XPCServiceDescription` has a `requiredEntitlement`
field; `FindMyLocate.ServiceEntitlements` enumerates them). Verified live:

```
$ launchctl print gui/$UID/com.apple.findmy.findmylocateagent   # endpoints
  com.apple.findmy.findmylocate.locationservice
  com.apple.findmy.findmylocate.friendshipservice
  com.apple.findmy.findmylocate.fenceservice
  com.apple.findmy.findmylocate.settings
```

But Messages passes all four checks. **For people, geofences and location sharing, Messages
is already exactly as entitled as FindMy.app is.** A helper there buys nothing. (Being
entitled is not the same as having an API — see §7 on geofences, where both hosts are equally
permitted and equally stuck.)

What FindMy.app genuinely has and Messages does not is one family — Find My **network items**,
plus device management:

```
com.apple.icloud.searchpartyd.ownersession          AirTags / Find My network items
com.apple.icloud.searchpartyd.beaconmanager
com.apple.icloud.searchpartyd.securelocations
com.apple.icloud.searchpartyd.beaconsharing.access
com.apple.icloud.searchpartyd.pairingmanager
com.apple.icloud.searchparty.locationfetch.items
com.apple.icloud.findmydeviced.access               device management
com.apple.FindMyDevice.FindMyServiceValidation.access
```

Messages holds **none** of these. That, and only that, is the case for a FindMy helper.

---

## 7. FindMy.app — one surface worth having

**Short version: the port's existing FindMy support, via `IMFMFSession` inside Messages, is
already the right answer for people and locations. A FindMy helper buys AirTags, and nothing
else.** The rest of this section is the evidence, because "we checked and there's nothing
there" is only useful if the next person can see what was checked.

### What the port already covers, from Messages

`IMFMFSession` (78 methods) and `FindMyLocateSession` (36) are both reachable today —
`IMFMFSession` is an IMCore class, and it dlopens `FindMyLocateObjCWrapper` itself. Between
them:

| Capability | Where | In the port today |
|---|---|---|
| Friends sharing location with me | `-findMyHandlesSharingLocationWithMe`, `-cachedFriendsSharingLocationsWithMe` | ✓ `findmy-friends` |
| Friends following my location | `-getFriendsFollowingMyLocationWithCompletion:` | partial |
| A friend's location | `-findMyLocationForHandle:`, `-cachedLocationForHandle:includeAddress:` | ✓ |
| Force a location refresh | `-refreshLocationForHandle:inChat:`, `-startRefreshingLocationForHandles:priority:isFromGroup:reverseGeocode:completion:` | ✓ `refresh-findmy-location` |
| Ask a friend to share | `-sendFriendshipInviteToHandle:isFromGroup:completion:` | ✓ `request-findmy-location-share` |
| Share my location | `-startSharingWithChat:withDuration:` | ✓ `start-sharing-findmy-location` |
| Stop sharing | `-stopSharingWithChat:`, `-stopSharingLocationWith:isFromGroup:completion:` | ✓ `stop-sharing-findmy-location` |
| Friendship state / offer expiry | `-friendshipStateWithHandle:isFromGroup:completion:`, `-cachedOfferExpirationForHandle:groupId:` | not wired |
| Active sharing device | `-activeDevice`, `-makeThisDeviceActiveDevice`, `-setActiveDevice:` | not wired |
| Live events | five `__kIMFMFSession*` notifications (rung 1) | ✓ documented in `headers/README.md` |

The unwired rows are small additions to the **existing** helper. Nothing in that column needs
a new host app.

### A correction to `docs/headers/README.md` — right conclusion, wrong reason

The README says of the legacy Objective-C helper's headers:

> They describe `FMFSessionDataManager`, `FMFSession`, `FMFHandle` and `FMFLocation`. On
> macOS 26.5.2 **none of those classes exist**.

The classes do exist, in `FMF.framework`, which FindMy.app links and Messages does not:

```
FMFSession 168 methods   FMFSessionDataManager 18   FMFHandle 56   FMFLocation 79
FMFDevice 23             FMFFence 67                FMFFriendshipRequest 18
```

So "none of those classes exist" wants rescoping to "none of them are in IMCore". **But the
README's practical conclusion — don't build on them — turns out to be right anyway, for a
better reason than absence: `FMFSession` is a dead client.** `-[FMFSession __connection]`
opens an `NSXPCConnection` to `com.apple.icloud.fmfd`, and nothing on macOS 26.5.2 vends that
service. There is no `/usr/libexec/fmfd`; the only `fmfd` endpoint in the user's launchd
domain is `com.apple.icloud.fmfd.aps`, a push endpoint on `findmylocateagent`. FindMy.app
links `FMF.framework` for its **model types** — `FMFFence`, `FMFHandle`, `FMFLocation` are
still passed around by the live code — not for its session.

Headers for all seven are checked in regardless. A dead API you can see is cheaper than one
you rediscover.

### The Swift wall

`FMIPCore` and `FMFCore` are the app's own controllers — `FMIPManager`, `FMIPDataManager`,
`FMIPDeviceActionsController`, `FMFManager`, and the whole `FMIP*Action` family
(`FMIPPlaySoundDeviceAction`, `FMIPLostModeAction`, `FMIPEraseAction`, …). They are **pure
Swift with no Objective-C exposure**:

```
FMIPCore.FMIPManager                  inst=0  cls=0  prop=0
FMIPCore.FMIPDataManager              inst=0  cls=0  prop=0
FMIPCore.FMIPDeviceActionsController  inst=0  cls=0  prop=0
FMFCore.FMFManager                    inst=0  cls=0  prop=0
```

`class_copyMethodList` returns nothing, so `IMCoreRuntime.send(...)` cannot reach them and no
selector-based approach will. They are deliberately **not** in `dump.sh` — dumping them emits
empty `@interface` blocks that read as "class exists, has no API", which is worse than
absent. The layer below them is classic Objective-C, and that is what a helper would call.

### Geofences are a dead end — in BOTH hosts

This looked like the headline feature and it is not available at all. Worth writing down in
full, because the trail is exactly the kind that gets walked twice.

**There is exactly one Objective-C geofence API on the whole system.** A sweep of every
selector in every loaded class containing `fence`, with the graphics/Metal/window-server
noise removed, leaves one class:

```
FMF   FMFSession   -addFence:completion:   -deleteFence:completion:   -getFences:
                   -fencesForHandles:completion:   -muteFencesForHandle:untilDate:completion:
                   -triggerWithUUID:forFenceWithID:withStatus:forDate:completion:
```

`FindMyLocateObjCWrapper` has no fence methods. IMCore has none. SPOwner has none.

**And `FMFSession` is a dead client.** `-[FMFSession __connection]` builds its
`NSXPCConnection` to `com.apple.icloud.fmfd` — recovered from the disassembly, +960 — and on
macOS 26.5.2 nothing vends that service. There is no `/usr/libexec/fmfd`, and the only
`fmfd` endpoint in the user's launchd domain is `com.apple.icloud.fmfd.aps`, the push
endpoint on `findmylocateagent`. FindMy.app links `FMF.framework` for its model types
(`FMFFence`, `FMFHandle`, `FMFLocation` are still passed around); the session is legacy.

The live fence transport is `FindMyLocate.Session.FenceConnection` — and `FindMyLocate.Session`
is **pure Swift, zero Objective-C members**, the same wall as `FMIPCore`. So geofences are
unreachable by selector dispatch from *any* host. **Injecting into FindMy.app does not help.**

There is one door left, and it should be recorded as open-but-not-worth-it. The fence service
protocol *is* an `@objc` protocol — `NSProtocolFromString("FindMyLocate.FenceServiceDaemonXPC")`
resolves — so a helper could open its own `NSXPCConnection` to
`com.apple.findmy.findmylocate.fenceservice`, and **Messages already holds that entitlement**,
so the daemon would accept it. The problem is the interface:

```objc
@protocol FindMyLocate.FenceServiceDaemonXPC
- (void)request:(id)arg0 completion:(id)arg1;   // that's the whole protocol
@end
```

One opaque method whose payload is a Swift value encoded by FindMyLocate's own binary coder
(`FindMyBase.BinaryDataEncoderStorage`, `BinaryDecodingContainer`). Using it means
reverse-engineering both the request enum and the encoding, with no type information and no
stability guarantee across releases. **Recommend: no.**

### Reachable: items / AirTags (`SPOwner.framework`)

Entirely new territory — nothing in the port touches this today.

```objc
SPBeaconManager   -allBeaconsWithCompletion:      -beaconForUUID:completion:
                  -allBeaconsOfTypes:includeDupes:includeHidden:completion:
                  -fetchUserStatsForBeacon:completion:
SPOwnerSession    -executeCommand:completion:     -locationsForBeacons:completion:
                  -addSafeLocation:completion:    -assignSafeLocation:beaconUUIDs:completion:
                  -removeSafeLocation:completion:
```

Commands are built by `SPCommand` class methods and handed to `-[SPOwnerSession
executeCommand:completion:]`:

```objc
+ (id)playSoundWithBeaconUUID:(id)uuid;
+ (id)playSoundWithBeaconUUID:(id)uuid duration:(...);
+ (id)enableLostModeForBeaconUUID:(id)uuid message:(id)m phoneNumber:(id)p email:(id)e;
+ (id)disableLostModeForBeaconUUID:(id)uuid;
```

`SPBeacon` carries `name`, `identifier`, `serialNumber`, `batteryLevel`, `owner` (`SPHandle`),
`lostModeInfo`, `safeLocations`, `shares`, `groupIdentifier`, `role`, `accessoryProductInfo`.
Both `SPBeaconManager` and `SPOwnerSession` are plain `-init`, no shared instance.

So: **list AirTags, get their locations, play a sound, set and clear Lost Mode, manage safe
locations.** All Objective-C, all reachable.

### Reachable but should not be exposed: this Mac (`FindMyDevice.framework`)

`+[FMDFMMManager sharedInstance]` manages *this machine's* Find My Mac configuration:
`isFMMEnabled`, `isActivationLockedWithCompletion:`, `enableActivationLockWithCompletion:`,
`removeFMMAccountWithUsername:`, `disableFMMUsingToken:inContext:usingCallback:`, and
`eraseAllContentAndSettingsUsingCallback:`.

It is reachable, and nothing here should ever be wired to an HTTP route. It is listed so the
next person recognises it and stops, rather than rediscovering it and wondering.

### Not reachable: other devices

Listing your iPhone/iPad/Watch and playing a sound *on them* lives in `FMIPCore`, which is the
Swift wall above. `FMDFMMManager` is local-only. `FMFSession -getAllDevices` returns
`FMFDevice`, which is the *friend-location* notion of a device (which of a friend's devices is
broadcasting), not the Find My Devices tab.

Working around it would mean talking to `findmydeviced`'s XPC interface directly, or
reimplementing the `fmipservice` HTTP protocol against the tokens in the keychain. Both are
substantially more work than everything else in this document combined, and both are far more
fragile. **Recommend: skip devices, ship people and items.**

### The disk shortcut is gone — and the port already knows

Recorded for completeness rather than as news: `BBSystem/FindMy.swift` already gates on
`cacheIsEncrypted` (macOS 15+) and `findmy.devices` already returns `data: null` rather than
a 500, matching the Electron server. The measurement on 26.5.2 agrees — the caches at
`~/Library/Caches/com.apple.findmy.fmipcore/` (`Devices.data`, `Items.data`,
`SafeLocations.data`, `Owner.data`, `ItemGroups.data`) are binary plists holding exactly two
keys:

```
"encryptedData" => {length = 6130, bytes = 0x6ad23726…}
"signature"     => {length = 64,   bytes = 0x36256ec2…}
```

The part that IS new is what it means for the roadmap. `findmy.devices` is currently a
permanently-null endpoint, and the obvious repair — "inject into FindMy.app and read the
devices from memory instead" — **does not work**, because the device list lives in
`FMIPCore`, which is Swift-only (see *The Swift wall* above). There is no host from which
that endpoint can be revived by selector dispatch.

`Items.data` is the AirTag cache, and that one *does* have a live replacement:
`SPBeaconManager -allBeaconsWithCompletion:` from inside FindMy.app. So of the two dead
cache-backed endpoints, items is recoverable and devices is not.

Also worth a look while in here: `Settings.openFindMyOnStartup` (default **true**) launches
FindMy.app at startup, and `AppBehaviour.openFindMy()`'s doc comment still explains it as
refreshing "the caches the FindMy endpoints read". Those caches are encrypted and the devices
endpoint returns null regardless, so the setting's stated rationale no longer holds — though
launching FindMy would become genuinely necessary again, for a better reason, if the items
helper is ever built.

---

## 8. Notes.app — reachable, but ask whether it belongs

`NotesShared.framework` is a full Core Data stack and it is completely Objective-C, unlike
FindMy's controllers. Notes.app is a genuine macOS app (`platform 1`), so it is the one host
here that wants the **macOS** dumper rather than the Catalyst one.

### Entry point and model

```objc
+[ICNoteContext sharedContext]        // also +hasSharedContext, +startSharedContextWithOptions:
-[ICNoteContext managedObjectContext] // and workerManagedObjectContext, snapshotManagedObjectContext
-[ICNoteContext save:]                // and -saveImmediately
```

| Class | Size | What it holds |
|---|---|---|
| `ICNote` | 310 methods / 160 properties | `title`, `attributedString`, `noteAsPlainText`, `folder`, `account`, `isPinned`, `isPasswordProtected`, `isSharedViaICloud`, `isDeletedOrInTrash`, `identifier` |
| `ICFolder` | 145 / 76 | folder tree, smart folders |
| `ICAccount` | 162 / 95 | iCloud vs On My Mac vs Exchange |
| `ICAttachment` | 268 / 141 | with `ICAttachmentModel` subclasses for image, movie, audio, drawing, table, PDF, web, map, gallery |
| `ICNoteContext` | 118 / 43 | the store |
| `ICCloudContext` | 244 / 48 | CloudKit sync |

Creation and mutation are both there — `+newEmptyNoteInFolder:`, `+newNoteWithoutIdentifierInAccount:`,
`-setFolder:`, `-setIsPinned:`, `-addInlineAttachments:`, `-deleteFromLocalDatabase`,
`+createNoteForAirDropDocument:processAttributedString:completion:`.

### Why the helper, and not just the database

The store is at `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` and is
readable with the Full Disk Access the server already has:

```
ZICCLOUDSYNCINGOBJECT  ZICNOTEDATA  ZICATTACHMENT…  ZICINVITATION  ZICLOCATION
```

But note bodies live in `ZICNOTEDATA.ZDATA` as an opaque compressed blob, not as text, and
`ICNote.attributedString` / `-noteAsPlainText` is the decoder — in-process, correct, and free.
That is the argument for the helper over a database reader: reading the titles is easy either
way; reading the *bodies* is the whole feature, and the helper is what makes it a one-liner.
(This account has essentially no notes, so the on-disk blob encoding was not verified here —
only that the column is a blob and that `ICNoteData` exposes `data` plus
`cryptoInitializationVector` / `cryptoTag`.)

Password-protected notes stay closed: `isPasswordProtected`, and the `ICAccountCryptoStrategyV*`
/ `ICAttachmentCryptoStrategyV*` families gate them behind the note password. Do not plan
around reading those.

### The scope question

This one is worth asking out loud rather than answering in code, and the cost is *not* the
extra host app — that is routine (§6). BlueBubbles is an iMessage server; Notes is reachable
and cleanly modelled, but shipping it means owning a sync-conflict story against CloudKit and
taking on the blast radius of **write** access to a user's notes, for something no client
currently asks for. **Recommend: dump the headers now (done), and do not build it until a
client wants it.** The research is checked in either way, which is the cheap half — and if a
client does ask, §8 is a head start rather than a research project.

---

## 9. Revised order

The FindMy section moved this list a long way from where it started: the honest ranking now
puts almost everything back inside Messages.

1. Everything in §4 (Messages chats). No new host, no new socket, no new injection.
2. The unwired `IMFMFSession` / `FindMyLocateSession` rows in §7 — friendship state, offer
   expiry, friends-following-me, active sharing device. Small additions to the **existing**
   helper, same host, no new decisions.
3. Stop here unless AirTags are actually wanted. Everything below costs a fourth host app —
   which is a `Target`, a socket and a dylib (§6), not a redesign, but still a running
   FindMy.app for as long as the feature is on.
4. **If** AirTags are wanted: the FindMy helper, against `SPBeaconManager` + `SPOwnerSession`
   + `SPCommand`. List items, locate them, play a sound, set and clear Lost Mode.
5. Notes: headers only, until a client asks.
6. Not reachable at any rung, in any host, don't spend time: geofences (§7), the Find My
   Devices tab (§7), device play-sound / Lost Mode for Macs and iPhones.
7. Never: `FMDFMMManager`'s erase / activation-lock / disable-FMM surface.

---

## 10. Header inventory

`Tools/private-api/dump-headers.sh` now emits, into `docs/headers/macos-<version>/`:

| Host | Frameworks | Classes | Dumper |
|---|---|---|---|
| Messages.app | iOSSupport IMCore, IMSharedUtilities, ChatKit | `IMChat` `IMChatRegistry` `IMChatInfo` `IMMutedChatList` | Catalyst |
| Messages.app | iOSSupport IMCore + FindMyLocateObjCWrapper | `IMFMFSession` `IMFindMy*` `FindMyLocateSession` `FML*` `@FMFSessionDelegate` | Catalyst |
| FaceTime.app | TelephonyUtilities | `TU*` (15 classes + delegate) | Catalyst |
| FindMy.app | FMF, FindMyDevice, SPOwner | `FMFSession` `FMFSessionDataManager` `FMFDevice` `FMFHandle` `FMFFence` `FMFLocation` `FMFPlacemark` `FMFSchedule` `FMFFriendshipRequest` `SPOwnerSession` `SPBeaconManager` `SPBeacon` `SPBeaconLocation` `SPSafeLocation` `SPLostModeInfo` `FMDFMMManager` `FMDSharedConfiguration` | Catalyst |
| Notes.app | NotesShared, NotesSupport | `ICNote` `ICFolder` `ICAccount` `ICAttachment` `ICAttachmentModel` `ICNoteContext` `ICNoteContainer` `ICCloudContext` `ICNoteData` `ICSearchQuery` `ICInvitation` | macOS |

The `FMF*` classes are checked in even though `FMFSession` is a dead client (§7) — its model
types are still live, and a dead API you can read is cheaper than one you rediscover.

Re-dumping the IMCore-sourced FindMy headers against the Catalyst variant changed **only the
`// Image:` line** — the two IMCore copies agree on `IMFMFSession`, `IMFindMyHandle`,
`IMFindMyLocation`, `IMFindMyDevice` and `FindMyLocateSession`. The divergence described in
§0 is confined to `IMChat`. Every header records its source image, so which variant produced
a file is checkable rather than assumed.
