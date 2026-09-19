# macOS compatibility

What works on each macOS this server supports, and which private selector decides it.

## TL;DR: what works where

Two different things gate a feature, and mixing them up is the mistake this page exists to
prevent. **Almost everything here needs the Private API**, which is a setup step on your side.
A few things additionally need a newer macOS, which is not.

### What the Private API adds: on every supported release

Without it the server can do what AppleScript can do: send text, send an attachment, and start
a one-to-one conversation. That is the whole list. Everything below works on macOS 14, 15 and
26 alike once the helper is running.

| | Without the Private API | With it |
|---|:-:|:-:|
| Send text, send an attachment, start a 1:1 chat | ✅ | ✅ |
| Read messages, chats and attachments · events to clients | ✅ | ✅ |
| Improved message sending: subject lines, and a more reliable send | ⛔️ | ✅ |
| Bubble and screen effects | ⛔️ | ✅ |
| Threaded replies | ⛔️ | ✅ |
| Mentions | ⛔️ | ✅ |
| Edit a sent message | ⛔️ | ✅ |
| Unsend a message | ⛔️ | ✅ |
| Typing indicators | ⛔️ | ✅ |
| Mark as read or unread | ⛔️ | ✅ |
| Reactions: the six named ones | ⛔️ | ✅ |
| Stickers | ⛔️ | ✅ |
| Managing groups: rename, add or remove people, photo, leave | ⛔️ | ✅ |
| Start a **group** chat | Shortcut | ✅ |
| Pinning conversations | ⛔️ | ✅ |
| Muting conversations | ⛔️ | ✅ |
| Spam and junk | ⛔️ | ✅ |
| FaceTime from a client | ⛔️ | ✅ |
| Find My | ⛔️ | ✅ |

**These are separate rows and they compose.** Underneath, all four are fields on one send:
IMCore has no reply parameter, only a thread identifier, and effects and mentions are likewise
things a message carries rather than ways of sending one. So a reply can have an effect, a
subject and a mention. They are listed apart because a user wants them one at a time, and each
is decided by its own property on the message, which is what the catalog checks.

### What a newer macOS adds: on top of the above

| | 14 Sonoma | 15 Sequoia | 26 Tahoe |
|---|:-:|:-:|:-:|
| Reactions: any emoji | ⛔️ | ✅ | ✅ |
| Reactions: stickers | ⛔️ | ✅ | ✅ |
| Text formatting: bold, italics, underline, strikethrough | ⛔️ | ✅ | ✅ |
| Schedule a message (Send Later) | ⛔️ | ✅ | ✅ |
| Edit a scheduled message | ⛔️ | ✅ | ✅ |
| Polls | ⛔️ | ⛔️ | ✅ |
| Conversation backgrounds | ⛔️ | ⛔️ | ✅ |
| Screen Unknown Senders | ⛔️ | ⛔️ | ✅ |

✅ works &nbsp;·&nbsp; ⛔️ **not available**: either macOS itself lacks it, or the Private API
is not set up. Neither is a bug, and the server refuses both with a message saying which.

**There is no third state.** Everything this server does on Tahoe it now does on Sonoma and
Sequoia too, except where macOS itself lacks the feature. Getting there took twelve selector
ladders (§3b); an earlier version of this table had six rows meaning "your Mac supports this
and we call the wrong selector", and they are all closed.

† Junk reporting works on 14 and 15 through an older call that reports and relays to the
carrier together. On those releases "report, but not to my carrier" cannot be honoured as a
choice: the report happens either way. Reporting is the point, so it is treated as a floor
rather than a refusal.

† On Sonoma, shared contact cards work but whether the **avatar photo** resolves is the one
thing no dump has measured (§5). It falls back to no photo, so the worst case is a contact
card without a picture.

## 1. The executable half of this document

`Sources/BBPrivateAPICatalog` carries the same facts as the TL;DR, as code:
`PrivateAPICapability.all` declares each feature the Private API provides: both the ones
every release has and the ones macOS gates. Three things read it and nothing repeats it: the
version gates take their number from it, the settings screen enumerates it, and the tests
below re-derive it.

**A capability is written by hand. What it claims cannot be wrong for long**, and that is the
whole design: three separate checks, each closing a different way this could rot:

| The catalog could... | Caught by |
|---|---|
| declare a wrong macOS minimum | `evidence` names the class or selector that decides it; a test re-derives the minimum from `docs/headers/` and fails if they disagree. **Every one of the 23 has some**: including the two that looked like they could not, where a method asking the same question turned out to exist |
| **miss a feature entirely** | every capability names the `MessagesHelperAction`/`FaceTimeHelperAction` cases it covers, and a test walks *every* action, failing unless it is claimed or explicitly listed as not user-facing, with a reason |
| leak API vocabulary onto the screen | a test rejects any title, summary or heading containing a selector, a function, a framework or an Apple type prefix |

The middle row is the one that makes this a registry rather than a list. Adding a helper
action already fails to compile until `HelperDispatch` handles it; once it does, the coverage
test fails until somebody decides whether a user would recognise it. Both were verified by
adding a fake `pin-message` action and watching each gate fire in turn.

What is **not** automatic: writing the entry. Nothing infers a title or a one-line summary
from a selector, and nothing should: that copy is the product decision, and the tests exist
to make sure it is made rather than to make it.

A laddered feature IS in the catalog, as something the Private API adds on every release,
with every rung of its ladder as evidence, so the test fails if a future macOS drops them
all. What it is not is version-gated, because listing it that way would advertise an upgrade
that gains nothing.

## 2. The dumps

| Release | Build | Dumped | Messages.app | Absent classes |
|---|---|---|---|---:|
| **14.6.1** Sonoma | 23G93 | runtime, in a VM | Catalyst | 13 |
| **15.6.1** Sequoia | 24G90 | runtime, in a VM | Catalyst | 6 |
| **26.5.2** Tahoe | 25F84 | runtime, this project's target | Catalyst | 1 |

All three were read from the Objective-C **runtime**, out of a process built for the same
platform as each host app: `environment.txt` in each directory records
`com.apple.MobileSMS … catalyst`, so all three describe the IMCore that Messages actually
runs. Each was checked for the one failure that would invalidate it: a framework that fails
to load reports every one of its classes as absent, which is indistinguishable from a
removal. No framework failed on any of the three, and no header is present-but-empty.

Sequoia's directory replaces a borrowed third-party class-dump of the **native** frameworks,
which could not see ChatKit at all. Roughly two-thirds of the divergences this document used
to list were artefacts of that dump rather than real differences.

### Cell meanings

| | |
|---|---|
| `yes` | the selector is there, on a class that is there |
| **`no`** | the class is present and this selector is not; **fix with a ladder** |
| **`-`** | the class itself is not on this release; **fix with a version guard** |
| `?` | no header for that class in this dump. Not evidence of absence; nobody asked |

The distinction between **`no`** and **`-`** is the whole point, and §2 is built on it.

## 3. What needs a version guard, and what needs a ladder

Two different problems with two different fixes, and picking the wrong one is how a feature
that Apple merely renamed ends up refused on a release that supports it.

### 3a. Genuinely absent: these need a guard, and are what the catalog declares

The class does not exist. No selector will bring the feature back, so the request should be
refused before the helper is asked, with a sentence naming the release.

| Feature | Minimum | Guard today | Measured by |
|---|:-:|---|---|
| Emoji tapbacks | **15** | `checkEmojiReactionSupported` ✓ | `IMEmojiTapback`: absent 14, present 15 |
| Sticker tapbacks | **15** | class guard, names 15 ✓ | `IMStickerTapback`: absent 14, present 15 |
| Send Later | **15** | `MessageInterface.swift:953` ✓ | `CKSendLaterPluginInfo`: absent 14, present 15 |
| Polls | **26** | `checkPollsSupported` ✓ | `IMPollHelper`, `IMPollOption`: absent 14 **and 15** |
| Chat backgrounds | **26** | `checkChatBackgroundsSupported` ✓ | `refetchLocalTranscriptBackgroundAssetIfNecessary` |
| Screen Unknown Senders | **26** | `checkScreenUnknownSendersSupported` ✓ | `markAsKnownAndSaveInContacts:completion:`, `cachedIsKnownSender` |

Every guard is confirmed against real dumps of both older releases rather than inferred.

**Screen Unknown Senders was the one that was not merely missing a guard.** This table used
to read "**none**: reads default to `false`", which understated it: the WRITE was the
problem, not the read. `-markAsKnownAndSaveInContacts:completion:` is absent below 26, the
helper's invoke threw, a `do/catch` logged the throw and fell through to the state read, and
`POST /chat/:guid/known` answered **200 with the unchanged filter state** on Sonoma and
Sequoia. That is the same response a client gets when the call works and the flag does not
move, so nothing could tell them apart. Both halves are fixed: the interface refuses below 26
with a sentence, and the helper no longer swallows, which also stops it swallowing a genuine
IMCore refusal on 26 itself. `ScreenUnknownSendersGateTests` pins the floor to the catalog.

**Chat backgrounds was late rather than wrong, and is now gated too.** The call already
failed at the helper, through `translating`, so the client got `unavailableOnThisOS` rather
than a false success. What the guard changes is where the refusal happens, and that the
sentence names macOS Tahoe instead of a private selector the reader cannot act on. Every row
in this table now refuses at the interface.

**Only the download is gated, not the reads.** `GET :guid/background` and
`:guid/background/info` serve bytes Messages already cached on disk, require no helper, and
answer "no background" on a release that has none, which is a correct answer rather than an
error. The best-effort fetch the bytes route makes on the way past is not gated either: it
already reports whether it managed to ask, and `false` is honest below 26. Gating a READ
because the feature that writes it is newer would make the wallpaper unreadable on exactly
the configuration §2 says is the common one.

### 3b. Renamed or re-signed: these need a ladder, and all twelve have one

The feature exists on every release; Apple changed the selector. A version guard here would
refuse a working feature, which is why these are laddered rather than gated.

| Feature | 14.6.1 | 15.6.1 | 26.5.2 | Ladder |
|---|---|---|---|:-:|
| Edit a message | `…withNewPartText:backwardCompatabilityText:` | same | `…newPartTranslation:…` | ✓ |
| Leave a group | `leaveiMessageGroup` | `leave` / `leaveConversation` | same | ✓ |
| Typing indicators | `isIncomingTypingMessage` | `isTypingMessage` | same | ✓ |
| Mute state | `-[IMChat setMuteUntilDate:]` | `IMMutedChatList` | same | ✓ |
| Named tapbacks | association initializer | `+tapbackWithAssociatedMessageType:` | same | ✓ |
| Report junk | `reportJunkToCarrier` | `reportJunkToCarrier` | `reportJunk`, `reportJunkToCarrierViaRelay:` | ✓ |
| Recover from Junk | `recoverFromJunk` + `updateIsFiltered:` | same | `recoverFromJunkTo:` | ✓ |
| Outgoing FaceTime call | `dialWithRequest:completion:` | same | `dialWithRequest:completionWithError:` | ✓ |
| Send a sticker | no `accessibilityName:`, no `externalURI:` | current | current | ✓ |
| Invalidate a FaceTime link | `invalidateLink:completionHandler:` | 3-argument | 3-argument | ✓ |
| Availability fetch | `_fetchUpdatedStatusForHandle:completion:` | unprefixed | unprefixed | ✓ |
| Edit a scheduled message | *(no Send Later)* | `…atPartIndex:withNewPartText:` | `…newPartTranslation:` | ✓ |

**All twelve are laddered.** Two of them (junk reporting and outgoing FaceTime calls) were
broken on *both* older releases, which is how the Sequoia dump changed their priority: 14 and
15 share the older spelling and only 26 has the new one, so one ladder fixed two releases each.

Every ✓ above was verified by reading its call site, not by reading the tool. See below for
why that distinction is not pedantic.

### Reading the tool's numbers

`compare-releases.py` reports how many dispatched selectors are **absent on the older
release**, and that number does not move when a ladder is added: a laddered call still names
the 26-only selector, it just asks `responds(to:)` first. So treat that count as a list of
**candidates to check**, never as a count of bugs. This table is the answer to which is which,
and it is maintained by hand because the distinction is a judgement about control flow that
no selector index can see.

That is not a hypothetical failure mode. The availability-fetch row above was written into
this table as missing a ladder, and into `../TODO.md` as work to do, on the strength of the
tool listing it absent on 14.6.1, which it is. It had been laddered the whole time, at
`IMCoreObjects.swift:1413`. **Read the call site before believing a row here**, which is now
how every ✓ in this table was checked: each modern selector was confirmed to have its older
spelling present in `Helper/` outside a comment.

## 4. Capabilities

| Capability | 14 Sonoma | 15 Sequoia | 26 Tahoe | Decided by |
|---|:-:|:-:|:-:|---|
| Send, reply, edit, unsend | yes | yes | yes | `editMessage` ladders three generations |
| Typing indicators | yes | yes | yes | `isIncomingTypingMessage` ∥ `isTypingMessage` |
| Named tapbacks | via fallback | yes | yes | one-argument `IMTapback` constructor arrived in 15 |
| Emoji tapbacks | **-** | yes | yes | `IMEmojiTapback` |
| Sticker tapbacks | **-** | yes | yes | `IMStickerTapback` |
| Send a sticker | via fallback | yes | yes | `accessibilityName:` and `externalURI:` arrived in 15 |
| Mute / unmute a chat | via fallback | yes | yes | `IMMutedChatList` arrived in 15 |
| Pin conversations | yes | yes | yes | `IMPinnedConversationsController` |
| Leave a group | yes | yes | yes | three-rung ladder |
| Mark as spam | yes | yes | yes | `markAsSpam:isJunkReportedToCarrier:` on all three |
| Report junk | via fallback | via fallback | yes | `reportJunkToCarrier` on 14/15 reports and relays together |
| Recover from Junk | via fallback | via fallback | yes | `recoverFromJunk` then `updateIsFiltered:`: two calls, one on 26 |
| Screen Unknown Senders | **-** | **-** | yes | `markAsKnownAndSaveInContacts:completion:` |
| Send Later | **-** | yes | yes | `CKSendLaterPluginInfo` |
| Edit a scheduled message | **-** | via fallback | yes | `newPartTranslation:` is 26-only |
| Cancel a scheduled message | **-** | yes | yes | `cancelScheduledMessageItem:cancelType:` |
| Polls | **-** | **-** | yes | `IMPollHelper` |
| Chat backgrounds | **-** | **-** | yes | `refetchLocalTranscriptBackgroundAssetIfNecessary` |
| Nicknames | yes | yes | yes | `IMNickname`, avatar accessors included; §5 |
| Outgoing FaceTime call | via fallback | via fallback | yes | older block carries no error; the call is unaffected |
| Invalidate a FaceTime link | via fallback | yes | yes | `deleteReason:` arrived in 15 |
| Answer / end a FaceTime call | yes | yes | yes | `TUCallCenter` answer and disconnect paths |
| FaceTime caller-ID / group UUID fields | **-** | **-** | yes | `TUCall` properties, read through `try?` |
| FindMy locations | yes | yes | yes | `FMFSession` and friends, identical on all three |

Everything marked **broken** has an open entry in [`../TODO.md`](../TODO.md). A row marked
**-** needs no LADDER, which is what §3a means; it still needs a **guard**, so that the
release refuses the request with a sentence instead of accepting it and doing nothing. Read
"**-**" as "§3a owns this", never as "no code required": the sentence that used to stand here
said the latter, and `POST /chat/:guid/known` shipped without a guard behind it.

## 5. The hole that was here is closed

This section used to say that `IMNickname`, `IMNicknameAvatar` and `IMNicknameAvatarImage`
were unmeasured on Sonoma, and that the question was stuck because the VM had been deleted.
**Both halves are now out of date.** The VM was restored and all three releases were re-dumped
on 16 September 2026, against the same `hosts.conf`: 143 classes each, and §6 below is
generated from that.

What the re-dump settled:

- **The nickname avatar accessors exist on Sonoma.** `-avatar`, `-imageExists` and
  `-imageFilePath`, read through `try?` at `IMCoreBridge.swift:1493`–`1496`, are present on
  14.6.1, 15.6.1 and 26.5.2 alike; §6 now collapses them into `Messages accounts`'s
  "present on every release" list rather than showing three `?` cells. The §4 Nicknames row
  is `yes` on all three.
- **`+[IMTapback tapbackWithAssociatedMessageType:messageSummaryInfo:]` is present on
  Sonoma**, at `macos-14.6.1/IMTapback.h:21`, taking `(long long, id)`. Tahoe carries only the
  one-argument `+tapbackWithAssociatedMessageType:`. That is the shape `../TODO.md` wanted
  before laddering the reaction path off the association initializer; the ladder itself is
  still unwritten.

**What a header dump cannot settle, and so is still open:** whether
`-[IMChat setMuteUntilDate:]` on Sonoma writes where Messages *reads*. The selector is present
on all three releases and always was; the open question is runtime behaviour, which no runtime
dump answers. `CHAT_CONTROLS_PLAN.md` §0 measured the `CKDNDList` defaults store on Tahoe and
that does not transfer. It stays in `../TODO.md`.

**Read that distinction before trusting a `yes` in this document.** Every cell in §6 means
"the selector exists in the runtime on that release". It does not mean the call works, and the
mute row is the standing example of the gap.

## 6. Every dispatched selector, by category

Generated: do not hand-edit. Categories are `hosts.conf` groups, which is the categorisation
this repository already maintains, so this document cannot drift into a second taxonomy.
Selectors present on every release are collapsed; the ones that differ are the tables.

**Regenerate this after touching a ladder.** Adding a rung adds a selector the helpers
dispatch, so the counts here go stale the moment one lands: this section grew by three
`Messages chat` rows from the junk ladders alone. Nothing warns you; the numbers simply stop
matching the tool.

```bash
./Tools/private-api/compare-releases.py --matrix
```

### Messages chat

53 selectors the helpers dispatch; **24** differ between releases.

| Selector | Class | 14.6.1 | 15.6.1 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `_messageToReportJunk` | `IMChat` | **no** | yes | yes |
| `cachedIsKnownSender` | `IMChat` | **no** | **no** | yes |
| `cancelScheduledMessageItem:cancelType:` | `IMChat` | **no** | yes | yes |
| `editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:` | `IMChat` | yes | yes | **no** |
| `editMessageItem:atPartIndex:withNewPartText:newPartTranslation:backwardCompatabilityText:` | `IMChat` | **no** | **no** | yes |
| `editScheduledMessageItem:atPartIndex:withNewPartText:` | `IMChat` | **no** | yes | **no** |
| `editScheduledMessageItem:atPartIndex:withNewPartText:newPartTranslation:` | `IMChat` | **no** | **no** | yes |
| `editScheduledMessageItem:scheduleType:deliveryTime:` | `IMChat` | **no** | yes | yes |
| `editScheduledMessageItems:scheduleType:deliveryTime:` | `IMChat` | **no** | yes | yes |
| `isMutedChat:` | `IMMutedChatList` | **-** | yes | yes |
| `leaveiMessageGroup` | `IMChat` | yes | **no** | **no** |
| `markAsKnownAndSaveInContacts:completion:` | `IMChat` | **no** | **no** | yes |
| `muteChat:untilDate:` | `IMMutedChatList` | **-** | yes | yes |
| `muteChat:untilDate:syncToPairedDevice:` | `IMMutedChatList` | **-** | yes | yes |
| `muteIdentifiersForChat:` | `IMMutedChatList` | **-** | yes | yes |
| `recoverFromJunk` | `IMChat` | yes | yes | **no** |
| `recoverFromJunkTo:` | `IMChat` | **no** | **no** | yes |
| `refetchLocalTranscriptBackgroundAssetIfNecessary` | `IMChat` | **no** | **no** | yes |
| `reportJunk` | `IMChat` | **no** | **no** | yes |
| `reportJunkToCarrier` | `IMChat` | yes | yes | **no** |
| `reportJunkToCarrierViaRelay:` | `IMChat` | **no** | **no** | yes |
| `sharedList` | `IMMutedChatList` | **-** | yes | yes |
| `unmuteChatWithMuteIdentifiers:syncToPairedDevice:` | `IMMutedChatList` | **-** | yes | yes |
| `unmuteDateForChat:` | `IMMutedChatList` | **-** | yes | yes |

<details><summary>29 present on every release</summary>

`_setDisplayName:` `_supportsEditMessage` `allMessagesToReportAsSpam` `canLeaveChat` `chatForIMHandles:` `chatIdentifier` `deleteAllHistory` `deleteChatItems:` `deleteIMMessageItems:` `downloadPurgedAttachments` `existingChatWithGUID:` `filterCategory` `guid` `isFiltered` `lastIncomingMessage` `lastSentMessage` `leave` `leaveConversation` `markAsSpam:` `markAsSpam:isJunkReportedToCarrier:` `markChatItemAsNotifyRecipient:` `muteUntilDate` `pinnedConversationIdentifierSet` `sendGroupPhotoUpdate:` `sendMessage:` `setMuteUntilDate:` `setPinnedChats:withUpdateReason:` `sharedRegistry` `updateIsFiltered:`

</details>

### Messages send

64 selectors the helpers dispatch; **4** differ between releases.

| Selector | Class | 14.6.1 | 15.6.1 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `customAcknowledgementMessageWithPayloadData:associatedMessageGUID:balloonBundleID:messageSummaryInfo:threadIdentifier:` | `IMMessage` | **no** | **no** | yes |
| `inUnknownSendersFilter` | `CKConversation/IMChat` | **no** | **no** | yes |
| `isIncomingTypingMessage` | `IMMessage/IMMessageItem` | yes | yes | **no** |
| `setSendLaterPluginInfo:` | `CKComposition` | **no** | yes | yes |

<details><summary>60 present on every release</summary>

`_imMessageItem` `_newChatItems` `_persistentPathForTransfer:filename:highQuality:chatGUID:storeAtExternalPath:` `acceptTransfer:` `addRecipientHandles:` `aggregateAttachmentParts` `audioCompositionWithMediaObject:` `breadcrumbMessageWithText:associatedMessageGUID:balloonBundleID:fileTransferGUIDs:payloadData:threadIdentifier:` `canInsertMoreRecipients` `canSendComposition:error:` `compositionByAppendingMediaObject:` `compositionByAppendingText:` `compositionWithMSMessage:appExtensionIdentifier:` `conversationForExistingChatWithGUID:` `deleteConversation:` `editMessageItem:partIndex:withNewComposition:` `guidForNewOutgoingTransferWithLocalURL:` `handles` `initWithConversation:` `initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:` `initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:` `initWithText:subject:` `isCancelTypingMessage` `isFromMe` `isIncoming` `isMuted` `isPinned` `isTypingMessage` `loadMessageItemWithGUID:completionBlock:` `loadMessageWithGUID:completionBlock:` `localPath` `markAllMessagesAsRead` `markLastMessageAsUnread` `mediaObjectWithFileURL:filename:transcoderUserInfo:` `mediaObjectWithSticker:stickerUserInfo:` `messageWithComposition:` `messagesFromComposition:` `pinningIdentifier` `registerTransferWithDaemon:` `removeRecipientHandles:` `retargetTransfer:toPath:` `retractMessagePart:` `sendMessage:newComposition:` `setDisplayName:` `setExpressiveSendStyleID:` `setLocalURL:` `setLocalUserIsTyping:` `setThreadIdentifier:` `setThreadOriginator:` `sharedConversationList` `sharedInstance` `shelfPluginPayload` `stickerCompositionWithMediaObjects:` `superFormatText:` `text` `title` `transfer` `transferForGUID:` `transferState` `wasDetectedAsSMSSpam`

</details>

### Messages stickers

10 selectors the helpers dispatch; **6** differ between releases.

| Selector | Class | 14.6.1 | 15.6.1 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `initWithStickerID:stickerPackID:fileURL:accessibilityLabel:accessibilityName:moodCategory:stickerName:` | `IMSticker` | **no** | yes | yes |
| `initWithStickerID:stickerPackID:fileURL:accessibilityLabel:moodCategory:stickerName:` | `IMSticker` | yes | **no** | **no** |
| `initWithTransferGUID:isRemoved:` | `IMStickerTapback` | **-** | yes | yes |
| `tapbackWithAssociatedMessageType:` | `IMTapback` | **no** | yes | yes |
| `userInfoDictionaryWithLayoutIntent:parentPreviewWidth:xScalar:yScalar:scale:rotation:initialFrameIndex:stickerPositionVersion:` | `IMSticker` | yes | **no** | **no** |
| `userInfoDictionaryWithLayoutIntent:parentPreviewWidth:xScalar:yScalar:scale:rotation:initialFrameIndex:stickerPositionVersion:externalURI:` | `IMSticker` | **no** | yes | yes |

<details><summary>4 present on every release</summary>

`conversation` `location` `setBallonBundleID:` `transferGUID`

</details>

### Messages tapbacks

7 selectors the helpers dispatch; **1** differ between releases.

| Selector | Class | 14.6.1 | 15.6.1 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `initWithEmoji:isRemoved:` | `IMEmojiTapback` | **-** | yes | yes |

<details><summary>6 present on every release</summary>

`initWithTapback:chat:messagePartChatItem:` `message` `messagePartRange` `send` `threadIdentifier` `threadOriginator`

</details>

### Messages sendlater

3 selectors the helpers dispatch; **2** differ between releases.

| Selector | Class | 14.6.1 | 15.6.1 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `initWithSelectedDate:` | `CKSendLaterPluginInfo` | **-** | yes | yes |
| `optionIdentifier` | `IMPollOption` | **-** | **-** | yes |

<details><summary>1 present on every release</summary>

`version`

</details>

### Messages apps

7 selectors the helpers dispatch; **2** differ between releases.

| Selector | Class | 14.6.1 | 15.6.1 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `_payloadDataFromAppName:adamID:` | `_MSMessageCustomAcknowledgement` | **-** | **-** | yes |
| `initWithSession:isFromMe:time:` | `_MSMessageCustomAcknowledgement` | **-** | **-** | yes |

<details><summary>5 present on every release</summary>

`initWithAlternateLayout:` `initWithSession:` `setCaption:` `setLayout:` `setSummaryText:`

</details>

### Messages stickerstore

3 selectors the helpers dispatch; **0** differ between releases.


<details><summary>3 present on every release</summary>

`donateStickerToRecentsWithIdentifier:representations:stickerEffectEnum:externalURI:name:accessibilityName:metadata:attributionInfo:error:` `initWithAdamID:bundleIdentifier:name:` `initWithData:type:size:role:`

</details>

### Messages accounts

30 selectors the helpers dispatch; **2** differ between releases.

| Selector | Class | 14.6.1 | 15.6.1 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `_fetchUpdatedStatusForHandle:completion:` | `IMHandleAvailabilityManager` | yes | **no** | **no** |
| `fetchUpdatedStatusForHandle:completion:` | `IMHandleAvailabilityManager` | **no** | yes | yes |

<details><summary>28 present on every release</summary>

`_aliasInfoForAlias:` `activeAccounts` `activeIMessageAccount` `activeSMSAccount` `aliases` `allowHandlesForNicknameSharing:forChat:fromHandle:forceSend:` `allowHandlesForNicknameSharing:fromHandle:forceSend:` `allowsSMSRelay` `availabilityForHandle:` `avatar` `currentIDStatusForDestinations:service:listenerID:queue:completionBlock:` `firstName` `forceRefreshIDStatusForDestinations:service:listenerID:queue:completionBlock:` `imHandleWithID:` `imageExists` `imageFilePath` `isConnected` `isSMSRelayCapable` `lastName` `login` `loginIMHandle` `loginStatusMessage` `nickname` `nicknameForHandleIDs:` `personalNickname` `shouldOfferNicknameSharingForChat:` `strippedLogin` `vettedAliases`

</details>

### Messages events

5 selectors the helpers dispatch; **0** differ between releases.


<details><summary>5 present on every release</summary>

`addHandler:` `connected` `listener` `removeHandler:` `sharedController`

</details>

### Messages findmy

27 selectors the helpers dispatch; **0** differ between releases.


<details><summary>27 present on every release</summary>

`activeDevice` `address` `altitude` `cachedFriendsFollowingMyLocation` `coarseAddressLabel` `disableLocationSharing` `findMyHandleIsFollowingMyLocation:` `findMyHandleIsSharingLocationWithMe:` `findMyHandlesSharingLocationWithMe` `findMyLocationForFindMyHandle:` `fmfLocation` `fmlLocation` `fmlSession` `handleWithIdentifier:` `imIsProvisionedForLocationSharing` `initWithIdentifier:` `latitude` `locationTypeDescription` `longitude` `restrictLocationSharing` `sendFriendshipInviteToHandle:isFromGroup:completion:` `session` `startRefreshingLocationForHandles:priority:isFromGroup:reverseGeocode:completion:` `startSharingWithChat:withDuration:` `startSharingWithHandle:inChat:withDuration:` `stopSharingWithChat:` `stopSharingWithHandle:inChat:`

</details>

### FaceTime

53 selectors the helpers dispatch; **4** differ between releases.

| Selector | Class | 14.6.1 | 15.6.1 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `callerIDBlocked` | `TUCall/TUProxyCall` | **no** | **no** | yes |
| `conversationGroupUUID` | `TUCall` | **no** | **no** | yes |
| `dialWithRequest:completionWithError:` | `TUCallCenter` | **no** | **no** | yes |
| `invalidateLink:deleteReason:completionHandler:` | `TUConversationManagerXPCClient` | **no** | yes | yes |

<details><summary>49 present on every release</summary>

`AVConferencePreviewSingleton` `activatedConversationLinks` `activeConversationForCall:` `activeLightweightParticipants` `activeRemoteParticipants` `answerOrJoinCall:` `approvePendingMember:forConversation:` `callStatus` `callUUID` `callWithCallUUID:` `conversationsByGroupUUID` `currentCalls` `dataSource` `dateReceivedLetMeIn` `delegate` `dialWithRequest:completion:` `disconnectCall:` `displayName` `expirationDate` `fetchInitialStateWithCompletionHandler:` `generateLinkForConversation:completionHandler:` `generateLinkWithInvitedMemberHandles:linkLifetimeScope:completionHandler:` `getActiveLinksWithCreatedOnly:completionHandler:` `groupUUID` `incomingPendingConversationsByGroupUUID` `initWithProvider:` `invalidateLink:completionHandler:` `isLightweightMember` `isPreviewRunning` `isSendingVideo` `joinedFromLetMeIn` `lightweightMembers` `linkName` `localMember` `normalizedEmailAddressHandleForValue:` `normalizedGenericHandleForValue:` `normalizedHandleWithDestinationID:` `normalizedPhoneNumberHandleForValue:isoCountryCode:` `pendingMembers` `providerManager` `registerWithCompletionHandler:` `remoteMembers` `setDelegate:` `setIsSendingVideo:` `setMuted:` `setVideo:` `stopPreview` `validityErrors` `value`

</details>

### FindMy

19 selectors the helpers dispatch; **0** differ between releases.


<details><summary>19 present on every release</summary>

`addHandles:` `deviceName` `forceRefresh` `formattedAddressLines` `getHandlesSharingLocationsWithMe` `handle` `horizontalAccuracy` `identifier` `isLocatingInProgress` `isThisDevice` `label` `locationType` `longAddress` `removeHandles:` `setHandle:` `setHandles:` `shortAddress` `streetAddress` `timestamp`

</details>

### Notes

4 selectors the helpers dispatch; **0** differ between releases.


<details><summary>4 present on every release</summary>

`URL` `fullName` `participants` `setURL:`

</details>
