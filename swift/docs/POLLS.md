# Polls

What an iMessage poll actually is, what this server would have to send to make one, and what
a client has to do to show one. Measured on macOS 26.5.2 (Tahoe) from real poll threads in
`chat.db` and by disassembling ChatKit, IMCore and Messages.framework.

**Status: researched, not built.** Nothing in the server sends a poll or a vote yet. The read
side already carries everything a client needs (see § What a client gets today). The send side
is designed here from Apple's own code path but has not been run — treat every "send" section
as a plan, not a description of working code.

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
| `2` | The poll, **updated** — an option added or edited | the ORIGINAL poll's GUID | the whole poll again, in its new state |
| `4000` | One participant's **vote** | the GUID of the most recent poll-state message (`3`, or the latest `2`) | that voter's votes |

Observed on a real thread here (GUIDs shortened):

```
FA3F941D  type 3     -> FA3F941D   poll created, 3 options
70DB8EC5  type 4000  -> FA3F941D   a vote
6C157B7B  type 4000  -> FA3F941D   a vote
CED3396B  type 4000  -> FA3F941D   a vote
3CC5FC21  type 2     -> FA3F941D   poll updated: a 4th option added
C2E97DC1  type 4000  -> 3CC5FC21   a vote, now against the UPDATED poll
78FD4E3E  type 4000  -> 3CC5FC21   our own vote
```

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

## 5. What the server should add

Two read helpers and two writes. Nothing here is built; this is the proposal.

### Read: decode it once, server-side

The archive walk is the same for every client and is easy to get wrong. A v2 read route should
return the poll already assembled:

```
GET /api/v2/message/:guid/poll
```

```json
{ "status": 200, "data": {
  "guid": "FA3F941D-…", "title": "Dinner?",
  "creatorHandle": "someone@example.com",
  "sessionId": "609D6A68-24D1-4D15-B54C-2CBB576758DC",
  "options": [ { "id": "16D8D418-…", "text": "Pizza", "creatorHandle": "…", "canBeEdited": false } ],
  "votes":   [ { "handle": "someone@example.com", "optionIds": ["16D8D418-…"], "date": 1788… } ],
  "latestStateGuid": "3CC5FC21-…"
} }
```

`latestStateGuid` matters: it is what a vote must be associated with, and only the server can
know it cheaply (it is the newest `type 2` in the chain, or the root).

The tally is deliberately NOT computed here — one vote per participant, latest wins, is a rule
a client can apply and a server that guesses wrong is worse than no server help.

### Write: create a poll

```
POST /api/v2/message/poll
{ "chatGuid": "…", "title": "Dinner?", "options": ["Pizza", "Sushi"] }
```

The server mints an `optionIdentifier` UUID per option and a `sessionIdentifier` UUID for the
poll, builds the JSON, wraps it in the archive, and sends. Answers with the serialised message,
like every other send route.

### Write: vote

```
POST /api/v2/message/poll/:guid/vote
{ "chatGuid": "…", "optionIds": ["16D8D418-…"] }
```

`:guid` is the poll's ROOT guid; the server resolves the latest state message itself. The body
is the voter's **complete** selection — an empty array retracts every vote. The server fills in
`participantHandle` from the account's own address.

---

## 6. How a send would work in the helper

From `+[CKComposition compositionWithMSMessage:appExtensionIdentifier:]` and
`-[CKCoreChatController transcriptCollectionViewController:balloonViewDidRequestSendCustomAcknowledgementPayload:forPlugin:error:]`,
both disassembled on 26.5.2.

**Creating a poll** — two routes into the same place:

1. *Through ChatKit, the way the extension does it.* Build an `MSMessage` (`Messages.framework`,
   `@iosfw/Messages.framework` in `hosts.conf`) with its `URL`, `layout` and `session`, then
   `+[CKComposition compositionWithMSMessage:appExtensionIdentifier:]` →
   `-[CKConversation sendMessage:newComposition:]`. ChatKit does the archive encoding, looks the
   plugin up through `+[IMBalloonPluginManager sharedInstance] balloonPluginForBundleID:`, and
   attaches the app icon. Closest to Apple's path; depends on the most surface.
2. *Build the payload directly.* `NSKeyedArchiver` the dictionary in § 3 and hand it to the
   `IMMessage` initializer that takes `balloonBundleID:payloadData:` — the one the helper already
   uses for text, with those two arguments filled in. Fewer moving parts, and the format is
   documented above, but the icon and the live-layout blob would be ours to reproduce.

Start with (1); fall back to (2) if `MSMessage` cannot be built outside an extension context.

**Voting** is its own IMCore call and does not need ChatKit at all:

```
+[IMMessage customAcknowledgementMessageWithPayloadData:associatedMessageGUID:balloonBundleID:messageSummaryInfo:threadIdentifier:]
```

ChatKit passes `associatedMessageGUID` as `bp:<poll state guid>` — the `bp:` prefix is how a
balloon payload association is addressed, the same way a tapback uses `p:<part>/<guid>`. The
prefix does not survive into `chat.db`, where the column holds the bare GUID. The summary info
comes from `+[IMChat configureMessageSummaryInfoForChatItem:]`, and the result is sent with
`-[CKCoreChatController sendCustomAcknowledgementMessage:]` or plain `-[IMChat sendMessage:]`.

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
3. **Render** from the newest state message in the chain — the latest `2`, or the `3` if there is
   none. Its option list is authoritative; options only ever get added, but text can change.
4. **Tally** by participant: group `4000` messages by `participantHandle` (or by the message's
   `handle`), keep only each participant's newest, and count the `voteOptionIdentifier`s in it.
   Never accumulate across a participant's messages — the newest one replaces the older.
5. **Vote** by posting the voter's full selection. Reflect it optimistically, then reconcile when
   the message row appears, exactly as with a sent message.
6. **Expect gaps.** A poll from a device that has never voted has no `4000` messages, and a
   participant who cleared their vote sends a `4000` with an empty `votes` array.

Until the routes in § 5 exist, steps 2 to 4 need `payloadData` on the read, and there is no way
to create a poll or vote through the API at all.

---

## 8. Open questions

- **Multi-select and titles.** Every poll observed here has `"title": ""` and one vote per
  participant. Whether the UI can produce a titled or multi-select poll, and what the JSON looks
  like when it does, has not been seen.
- **`liveLayoutInfo`** (318 bytes) is unexplained. A poll sent without it may render as a plain
  app balloon rather than a live one.
- **`ai`**, the app icon, is 4 KB of JPEG on every poll message. Whether the receiving device
  needs it or falls back to the installed extension's icon is unknown.
- **Adding an option** (`type 2`) is not covered above beyond its shape.
- Nothing here has been **sent**. The first poll this server sends is the test of all of it.
