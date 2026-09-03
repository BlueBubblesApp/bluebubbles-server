# Polls

What an iMessage poll actually is, what this server would have to send to make one, and what
a client has to do to show one. Measured on macOS 26.5.2 (Tahoe) from real poll threads in
`chat.db` and by disassembling ChatKit, IMCore and Messages.framework.

**Status: built, sent, and rendering.** `GET /api/v2/message/poll/:guid` assembles a poll from
its thread, `POST /api/v2/message/poll` creates one and `POST /api/v2/message/poll/:guid/vote`
votes. All three ran on 3 September 2026 against a real chat: the poll and the vote landed in
`chat.db` as `com.apple.messages.Polls` rows with the same payload shapes Apple's own carry, the
read route reproduces a six-participant thread Messages made, and the transcript on this Mac
draws the poll as a poll — three options, the vote filled in against its option. What has not
been checked is another participant's device — § 8.

Polls are **macOS 26 and newer**. `-[IMChat _supportsPolls]` and `-[CKConversation supportsPolls]`
gate them, and the Polls extension does not exist on earlier releases.

---

## 1. A poll is not a message type

There is no `is_poll` column and no poll flag. A poll is an **iMessage app message** — the same
mechanism third-party iMessage apps use — sent by Apple's own built-in extension:

| | |
|---|---|
| Extension bundle | `/System/iOSSupport/System/Library/Messages/iMessageApps/MessagesPolls.bundle` |
| `CFBundleIdentifier` | `com.apple.messages.Polls` |
| `balloon_bundle_id` on the row | `com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.messages.Polls` |

That balloon bundle id is how you recognise a poll, and it is the only thing that distinguishes
it from any other app balloon. The `0000000000` is the team id slot, which is literally that
string for Apple's own extensions (ChatKit builds it as `…BalloonPlugin:<teamID>:<bundleID>`,
substituting `0000000000` when there is no team).

The poll's content lives in **`payload_data`**, a `NSKeyedArchiver` blob. The message's `text`
is empty.

---

## 2. The thread: one poll, many messages

A poll is a conversation of its own inside the chat. Every state change is a new message that
points back at the poll with `associated_message_guid`.

| `associated_message_type` | What it is | `associated_message_guid` | `payload_data` |
|---|---|---|---|
| `3` | The poll, as created | its **own** GUID | the whole poll (title + options) |
| `2` | The poll, **re-sent in a new state** — this is what "Add Choice" produces, and what `POST …/option` sends | the ROOT poll's GUID | the whole poll again, with the new option |
| `4000` | One participant's **vote** | the GUID of the most recent poll-state message (`3`, or the latest `2`) | that voter's votes |

Observed on a real thread here (GUIDs shortened):

```
FA3F941D  type 3     -> FA3F941D   poll created, 3 options
70DB8EC5  type 4000  -> FA3F941D   a vote
6C157B7B  type 4000  -> FA3F941D   a vote
CED3396B  type 4000  -> FA3F941D   a vote
3CC5FC21  type 2     -> FA3F941D   the poll re-sent in a new state
C2E97DC1  type 4000  -> 3CC5FC21   a vote, now against the UPDATED poll
78FD4E3E  type 4000  -> 3CC5FC21   our own vote
```

**The root's type is not fixed.** A freshly created poll — ours or one made in Messages — lands
with `associated_message_type` **0** and no `associated_message_guid`. The moment its first
update arrives, Messages rewrites the root row to type **3** pointing at itself. So type 3
means "a poll that has been updated", type 0 "a poll nobody has changed yet", and a reader has
to accept both as a root. Measured on this Mac: the poll this server created sat at 0 until a
choice was added from Messages' own UI, then read 3.

Two more things the "Add Choice" control taught us, watching what it wrote:

- **Titles do not survive.** The poll was created here with a title; Messages' own re-send
  carried `"title": ""`. The Polls UI has no title field, so it does not preserve one. Treat
  `title` as write-only and probably invisible.
- **Every state re-send is a full copy**, so a server-made option and a UI-made option in the
  same poll coexist as long as each side builds its update from the latest state. Building it
  from an older state silently drops the other side's options — which is why the server reads
  the latest state at request time rather than trusting a client-supplied list.

Two consequences a client cannot ignore:

- **Votes chain to the latest poll state, not to the original.** Following
  `associated_message_guid` from a vote gets you a `type 2` message, and you have to follow
  ITS `associated_message_guid` to reach the poll's root. A poll's identity is the root GUID.
- `associated_message_range_length` is `-1` on updates and votes, `0` on the creation. It means
  nothing here; do not read it.

Types `2`, `3` and `4000` are not in the reference's reaction table, so they reach clients as
the strings `"2"`, `"3"`, `"4000"` — see § What a client gets today.

---

## 3. Inside `payload_data`

`payload_data` is `NSKeyedArchiver`-encoded (`$archiver`, `$objects`, `$top`). Decoding it
yields a dictionary of the app-message fields — this is `-[MSMessage _payloadDataFromAppIconData:appName:adamID:allowDataPayloads:]`
writing its `MSMessage` out:

| Key | Value on a poll | Value on a vote |
|---|---|---|
| `URL` | `NSURL` — `data:,<base64 JSON>?src=p&c=3` | `NSURL` — `data:,<base64 JSON>` |
| `an` | `"Polls"` (app name) | `"Polls"` |
| `ai` | app icon JPEG, ~4 KB | absent |
| `sessionIdentifier` | `NSUUID` — the `MSSession` tying the thread together | the same UUID |
| `ldtext` | `"Sent a poll"` | absent (the summary carries it) |
| `layoutClass` | `"MSMessageTemplateLayout"` | absent |
| `liveLayoutInfo` | ~318 bytes | absent |
| `userInfo` | the template layout's caption/subcaption strings | absent |

**The poll itself is the `URL`.** It is a `data:` URL whose body is base64 JSON. Note the query
string after the base64 (`?src=p&c=3`) — strip it before decoding or the base64 is invalid.

### The poll JSON

```json
{
  "version": 1,
  "item": {
    "title": "",
    "creatorHandle": "someone@example.com",
    "orderedPollOptions": [
      {
        "optionIdentifier": "16D8D418-28B5-4606-8A71-98C28D556B9C",
        "text": "Life insurance",
        "attributedText": "Life insurance",
        "canBeEdited": false,
        "creatorHandle": "someone@example.com"
      }
    ]
  }
}
```

`optionIdentifier` is a UUID minted by whoever added the option, and it is the only durable
handle on an option — `text` can be edited. `creatorHandle` appears both on the poll and on each
option, because participants can add options to someone else's poll.

### The vote JSON

```json
{
  "version": 1,
  "item": {
    "votes": [
      { "participantHandle": "someone@example.com",
        "voteOptionIdentifier": "16D8D418-28B5-4606-8A71-98C28D556B9C" }
    ]
  }
}
```

**A vote message carries that voter's complete selection, not a delta.** Multi-select polls put
several entries in `votes`; changing a vote means sending a new type-4000 message with the new
full list. So the current tally is: for each participant, take their LATEST type-4000 message
and count the identifiers in it.

`message_summary_info` on a vote carries the human-readable summary Messages shows in
notifications and the reference already serialises it:

```
amb = com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.messages.Polls
amc = 9            (content type: an app message)
amd = "Polls"      (plugin display name)
ams = "Sent a vote"
enc = true
ust = true
```

---

## 4. What a client gets today, with no server changes

Every field above is already reachable through the existing v1 read routes:

- `balloonBundleId` — recognise the poll (`…:com.apple.messages.Polls`).
- `associatedMessageType` — `"3"`, `"2"` or `"4000"` as strings.
- `associatedMessageGuid` — the chain described in § 2.
- `payloadData` — ask for it with `?with=payloadData` on `GET /message/:guid`, or
  `"with": ["payloadData"]` on `POST /message/query`. It arrives as the decoded property list,
  so the client sees the `$objects` graph and has to walk it to the `data:` URL.
- `messageSummaryInfo` — the `ams` summary line, with the same opt-in.

So a client can render polls **now**, at the cost of doing the `NSKeyedArchiver` walk and the
base64/JSON decode itself. That is the honest state of things.

---

## 5. The server's routes

All three are v2, additive, and answer 400 below macOS 26 ("Polls are only supported on
macOS 26 and newer"). Our own fields are snake_case, as every v2 response.

### Read: the poll, assembled

```
GET /api/v2/message/poll/:guid
```

`:guid` may be ANY message of the thread — the root, an update, or a vote — and resolves to
the poll. The reply:

```json
{ "status": 200, "data": {
  "guid": "FA3F941D-…",                      // the root
  "title": "Dinner?",
  "creator_handle": "someone@example.com",
  "session_id": "609D6A68-24D1-4D15-B54C-2CBB576758DC",
  "latest_state_guid": "3CC5FC21-…",         // newest type-2 update, or the root
  "options": [ { "id": "16D8D418-…", "text": "Pizza", "creator_handle": "…", "can_be_edited": false } ],
  "votes":   [ { "guid": "…", "handle": "someone@example.com", "option_ids": ["16D8D418-…"], "date": 1788… } ]
} }
```

`votes` is already ONE entry per participant, that participant's newest vote — the rule in § 7
applied for you. `options` come from the latest state message. The tally itself is left to the
client, since counting is trivial and a wrong server count would be worse than none.

### Write: create a poll

```
POST /api/v2/message/poll
{ "chatGuid": "…", "title": "Dinner?", "options": ["Pizza", "Sushi"] }
```

At least two non-empty options. The server mints an `optionIdentifier` UUID per option and the
helper mints the session; `creatorHandle` is the account's own address. Answers with the
serialised message, like every send route — recognisable by its `balloonBundleId`.

### Write: vote

```
POST /api/v2/message/poll/:guid/vote
{ "chatGuid": "…", "optionIds": ["16D8D418-…"] }
```

`:guid` is any message of the thread; the server resolves the latest state message to
associate the vote with. The body is the voter's **complete** selection — an empty array
retracts every vote — and every id must be an option on the poll. Answers with the vote's own
message row (`associatedMessageType` `"4000"`).

### Write: add a choice

```
POST /api/v2/message/poll/:guid/option
{ "chatGuid": "…", "text": "Purple" }
```

The poll re-sent in its new state: the server reads the latest state, appends the option with
a fresh identifier credited to this account (anyone may add a choice to anyone's poll), and
sends it in the poll's session. Answers with the update's message row
(`associatedMessageType` `"2"`, `associatedMessageGuid` = the root). Existing options keep
their identifiers and creators, so votes already cast stay valid.

**The server keeps no poll state.** Every route reads the thread from `chat.db` at request time
and forgets it. The only reason a write reads first is the wire format: an update must carry
every existing option with its original identifier, and a vote must name the latest state.

---

## 6. How the helper sends

From `+[CKComposition compositionWithMSMessage:appExtensionIdentifier:]` and
`-[CKCoreChatController transcriptCollectionViewController:balloonViewDidRequestSendCustomAcknowledgementPayload:forPlugin:error:]`,
both disassembled on 26.5.2.

**Creating a poll** goes through ChatKit the way the extension does (`IMPolls.composition`):
an `MSMessage` from `Messages.framework` (the public iMessage-app API, `@iosfw/` in
`hosts.conf`, `dlopen`ed on first use because Messages.app does not load it until an
extension runs) with its `URL`, an `MSMessageTemplateLayout` captioned "Sent a poll", and a
fresh `MSSession`; then `+[CKComposition compositionWithMSMessage:appExtensionIdentifier:]`
with `com.apple.messages.Polls`, `messagesFromComposition:`, `sendMessage:newComposition:`.
ChatKit does the archive, looks the plugin up and attaches the icon. Worked first time; the
row it produced is 2.9 KB against Apple's 6 KB, the difference presumably the `ai` icon and
`liveLayoutInfo` — see § 8.

**Voting** is IMCore's custom acknowledgement (`IMPolls.voteMessage`):
`_MSMessageCustomAcknowledgement` on the poll's session with the votes `data:` URL,
`_payloadDataFromAppName:adamID:` for the archive, then

```
+[IMMessage customAcknowledgementMessageWithPayloadData:associatedMessageGUID:balloonBundleID:messageSummaryInfo:threadIdentifier:]
```

and `-[IMChat sendMessage:]`. The associated GUID is the poll's latest state, BARE: ChatKit
formats `bp:<guid>` only to look the chat item up, and the column holds the bare value. The
summary is written directly (`amc 9`, `ams "Sent a vote"`, `amb`, `amd "Polls"`) rather than
through `+[IMChat configureMessageSummaryInfoForChatItem:]`, which wants a ChatKit chat item.
The vote payload came out 695 bytes — byte-for-byte the size of Apple's.

**Adding a choice** is the one that took three attempts, and the failures are the lesson:

1. *Same session, sent like a create.* Lands as a brand-new poll (type 0, no association).
   The session identifier alone does not make an update.
2. *Same session, plus `setAssociatedMessageGUID:` on the composition's plugin payload.*
   Still a new poll. ChatKit's `_messageFromPayload:firstGUID:` branches on
   `-[IMPluginPayload isUpdate]`, which is a bare ivar with no setter — only the extension
   host sets it, when it builds a payload for a message the user is updating.
3. *Reproduce the update branch directly.* Build the composition in the poll's session for its
   payload, then hand that payload to
   `+[IMMessage breadcrumbMessageWithText:associatedMessageGUID:balloonBundleID:fileTransferGUIDs:payloadData:threadIdentifier:]`
   with the ROOT guid, and `-[CKConversation sendMessage:newComposition:NO]`. The builder writes
   type 2 with flags 5 (disassembled), and the row matches what Messages' own "Add Choice"
   wrote to the byte in shape.

(`IMPolls.updateMessage`.) Confirmed on the Mac's transcript: the choice appears on the
existing poll, alongside one added from Messages' own UI. Attempt 1 left a stray four-option
poll in the test chat.

`IMPollHelper` (IMCore) exists and reads polls back — `pollOptionsFromPluginPayload:completionHandler:`,
`pollResponseFromChatItem:…`, `synchronousPollOptionCountFromChatItem:` — but its completion
handlers are Swift closures with mangled signatures that the ObjC runtime reports as dozens of
junk arguments, so they are not callable through `IMCoreRuntime`. Decoding the payload ourselves
(§ 3) is the supported route.

---

## 7. What a client should do

1. **Recognise** a poll: `balloonBundleId` ends `:com.apple.messages.Polls`.
2. **Group** by the root GUID. Walk `associatedMessageGuid` up from any `2` or `4000` message
   until you reach a message whose type is `3`; that GUID is the poll's identity. Cache it.
3. **Render** from the newest state message in the chain — the latest `2`, or the root (type
   `3`, or `0` if never updated). Its option list is authoritative; options only ever get
   added. Do not show `title`; Messages does not.
4. **Tally** by participant: group `4000` messages by `participantHandle` (or by the message's
   `handle`), keep only each participant's newest, and count the `voteOptionIdentifier`s in it.
   Never accumulate across a participant's messages — the newest one replaces the older.
5. **Vote** by posting the voter's full selection. Reflect it optimistically, then reconcile when
   the message row appears, exactly as with a sent message. **Add a choice** with
   `POST …/option`; the update row that comes back is the new latest state, so re-render from
   it — and expect other participants' choices to arrive the same way, as type-2 rows.
6. **Expect gaps.** A poll from a device that has never voted has no `4000` messages, and a
   participant who cleared their vote sends a `4000` with an empty `votes` array.

With `GET /api/v2/message/poll/:guid`, steps 2 to 4 are done for you: pass any message of the
thread and read `options` and `votes` back assembled. Steps 1 and 5 are the client's.

---

## 8. Open questions

- **Multi-select and titles.** Every poll observed here has `"title": ""` and one vote per
  participant. Whether the UI can produce a titled or multi-select poll, and what the JSON looks
  like when it does, has not been seen.
- **`liveLayoutInfo`** is `{layoutClass: MSMessageLiveLayout}` and it is REQUIRED: a poll sent
  with only a template layout arrived on this Mac as a plain "Sent a poll" balloon with an
  "Add Choice" button and no options. Wrapping the template in an `MSMessageLiveLayout` makes
  `MSMessage` write it, and the archive then carries Apple's exact key set.
- **`ai`**, the app icon, is 4 KB of JPEG on every poll message. Whether the receiving device
  needs it or falls back to the installed extension's icon is unknown.
- **Editing an existing option's text** is not built; only adding is. The JSON allows it
  (`canBeEdited`), and it would be the same type-2 re-send.
- **The other side.** Seen rendering on this Mac's own transcript; not yet on a participant's
  device. The rows had no delivery receipt after two minutes where a text gets one in seconds,
  which may just be how app messages report. Worth one look on a phone.
- **A stray poll.** Attempt 1 at adding a choice left a second, four-option "Live layout poll"
  in the test chat; it is a real poll and can be ignored or deleted.
