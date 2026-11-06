# Game Pigeon, and iMessage apps in general

How Game Pigeon messages are put together, what this server does with them, and what a client
has to do to actually play a game. Measured against real Game Pigeon threads, four different
games across five format versions: the payload format on macOS 26.5.2, and the image send on
macOS 27.0.1. If you only want to call the API, start at [Calling it](#calling-it).

The short version: **the server reads and writes the payloads, the client plays the games.**
That split is not a design preference, it is forced; see § 1.

---

## 1. Why the Mac cannot play

Game Pigeon is an iOS-only iMessage app. There is no Mac version, so the extension is not
installed on the server's Mac and never will be. Messages on macOS shows a received game as a
plain fallback bubble ("Let's play Cup Pong!") with no board and no controls.

So the Mac cannot render a game, cannot compute a move, and cannot be asked to. What it *can*
do is read the payload out of a message and put a new one back on the wire, which it turns out
is all a client needs: the game state travels in the message itself.

This server therefore offers a **flexible pass-through**: it decodes the payload into fields
and sends fields back. It does not know what "8 Ball" is, and deliberately so. There are two
dozen Game Pigeon games and they share nothing but the envelope.

---

## 2. The envelope: every iMessage app is the same shape

Game Pigeon, Polls, and any third-party iMessage app all send the same structure. The message
row carries:

- `balloon_bundle_id`: `com.apple.messages.MSMessageExtensionBalloonPlugin:<team>:<bundle>`.
  Game Pigeon's is `…:EWFNLB79LQ:com.gamerdelights.gamepigeon.ext`. The team id belongs to the
  developer, so match on the **suffix**, not the whole string.
- `payload_data`: an `NSKeyedArchiver` archive of the `MSMessage` the extension built.
- empty `text`.

Unarchived, that payload is a dictionary:

| Key | What it is |
|---|---|
| `URL` | the app's own payload: everything game-specific is in here |
| `an` | app name, for example `GamePigeon` |
| `appid` | App Store id: Game Pigeon is `1124197642` |
| `sessionIdentifier` | `MSSession` UUID, shared by every message of one game |
| `ldtext` | fallback summary line |
| `layoutClass` / `userInfo` | the template layout, whose `caption` is the human-readable line |
| `ai` | the app's icon, a few KB of JPEG |
| `liveLayoutInfo` | 318 bytes: a second keyed archive, of `{layoutClass: MSMessageLiveLayout, userInfo: {}}`. Present on every Game Pigeon message at format 50 and 52, absent at 49 and below. It marks the balloon LIVE, so the recipient's extension draws its own view; `layoutClass` at the top level stays the template, which is what a device without the app shows |

`AppMessagePayload` reads and writes this, and it is not Game Pigeon-specific: the poll code
uses the same reader.

One practical note on writing: ChatKit's `+[CKComposition compositionWithMSMessage:appExtensionIdentifier:]`
resolves the extension through the balloon plugin manager and **fails when the extension is not
installed**, which on a Mac is the normal case for a third-party app. So the server builds the
archive itself (plain Foundation types) and hands the bytes to the helper, which attaches them
to an `IMMessage` with `balloonBundleID:` and `payloadData:`. That path does not care whether
the Mac has ever heard of the app.

---

## 3. Game Pigeon's URL

This is the only part that is actually Game Pigeon's own:

```
data:?ver=<N>&data=<scrambled>
```

`ver` is Game Pigeon's format version: 42, 45, 48, 49, 50 and 52 have all been seen in the
wild, and they coexist because it is whatever version the sender's app was.

Game Pigeon is a third-party app, and none of this format is a supported interface. A `ver`
that isn't on that list is the first sign the format has moved.

`data` is **a permutation of a plain URL query string**. Not encryption, not compression: the
characters are shuffled with Fisher-Yates, driven by `drand48` seeded with `length * 0xEF`.
The only input is the string's own length, so it reverses with no secret at all. `drand48`
being the classic one:

```
state = (seed << 16) + 0x330E
next  = (25214903917 * state + 11) mod 2^48
drand = next / 2^48
```

Scrambling draws characters out of the remaining pool one at a time at
`floor(drand() * remaining.count)`. Unscrambling replays the same draws and undoes them. That
is the whole thing, and `GamePigeonCodec` is our own implementation of it, with a round-trip
test and vectors computed independently.

Unscrambled, you get an ordinary query string. A Cup Pong invite:

```
?sender=<id>&version=5&tver=5&ios=12.4.1&start=&caption=Let's play Cup Pong!
&id=NlHyspTMBsictrrI&player=2&player2=<id>&avatar2=body,1|eyes,4|…
&game=beer&game_name=Cup Pong&seed=947177914&mode=n&style2=0&num=1&build=…
```

Fields worth knowing, though none are guaranteed:

| Field | Meaning |
|---|---|
| `game` | the game's internal name: `beer` is Cup Pong, `pool` is 8 Ball, `pool3` is 8 Ball+, `crazy` is Crazy 8 |
| `game_name` | its display name, on invites |
| `id` | Game Pigeon's own game id, stable for the whole game, distinct from the `MSSession` UUID |
| `player`, `player1`, `player2` | whose turn it is, and the two player ids |
| `sender` | who sent this message: a UUID with six extra characters appended |
| `caption` | the line shown on the bubble |
| `seed` | the game's RNG seed, so both sides simulate the same thing |
| `avatar1`, `avatar2` | the pigeon avatars, as `body,5\|eyes,7\|mouth,5\|…` |
| `start` | present and empty on an invite |
| `replay` | the move itself. 8 Ball's is 2.4 KB of physics (`&d:…&x:…&y:…&balls:#…`) |

**Do not build a client around that table.** Every game puts what it likes in there: a word
game's fields look nothing like pool's, which is exactly why the API hands back a list of
name/value pairs and stops.

---

## 4. The API

### Calling it

Three routes, all under `/api/v2/message`. This section is the reference; the rest of § 4
explains why each one behaves the way it does. The full request and response schemas are in
[`docs/api/openapi.json`](api/openapi.json).

| Route | Does | Needs |
|---|---|---|
| `GET app/:guid` | Decodes one app balloon's payload | A subscription |
| `POST game-pigeon` | Sends a Game Pigeon balloon from a list of fields | A subscription and the Private API |
| `POST app` | Sends any other iMessage app's balloon | A subscription and the Private API |

**Before you call.** Authenticate exactly as on v1 (`?password=`, or an `Authorization`
header; see [the API overview](api/README.md#authentication)). A server without a
subscription answers `402` with `error.type` `Payment Required`, and a server whose Private
API helper is not connected answers the two sends with a `500` `iMessage Error`. Neither is a
malformed request, so show the user why rather than retrying.

#### `POST game-pigeon`

| Field | | |
|---|---|---|
| `chatGuid` | required | The chat to send into |
| `fields` | required | The game's fields: an ordered list of `{"name", "value"}`, or a plain object when order does not matter. Must be the COMPLETE set for the game; see [below](#send-a-complete-field-set-or-the-recipient-is-told-to-update-the-app) |
| `sessionId` | optional | A UUID. Omit it on an invite and the server mints one; on a move, send the session of the message you are answering |
| `caption` | optional | The balloon's caption, for example `Let's play Cup Pong!` |
| `image` | optional | The picture the balloon draws: base64 JPEG, PNG or HEIC, at most 4 MB. A `data:image/…;base64,` prefix is accepted. See [the image](#the-balloons-image-is-an-attachment-and-the-client-draws-it) |
| `tempGuid` | optional | Your placeholder's id, echoed back; see [matching a send](#matching-a-send-to-its-placeholder) |
| `liveLayout` | optional | `true` writes the live-layout marker a current Game Pigeon sends on every message. Default `false`; see [the live layout](#a-later-turn-is-a-session-update-and-a-live-balloon-draws-the-game) |
| `version` | optional | The outer payload format, the `ver` in the URL. Defaults to `52` |
| `teamId` | optional | The extension's team id. Defaults to Game Pigeon's own, `EWFNLB79LQ` |

Leave `sender`, `version`, `tver` and `ios` out of `fields`: the server fills them in
([why](#send-a-complete-field-set-or-the-recipient-is-told-to-update-the-app)). Anything you
do put there is sent exactly as you wrote it, so a move can echo the `version` it answers.

```bash
curl -X POST "http://localhost:1234/api/v2/message/game-pigeon?password=…" \
  -H 'Content-Type: application/json' \
  -d @- <<'EOF'
{
  "chatGuid": "any;-;+15555550100",
  "caption": "Let's play Cup Pong!",
  "liveLayout": true,
  "tempGuid": "5D1F0C3A-8B7E-4F2A-9C61-0E4B7A2D9F13",
  "fields": [
    { "name": "start",     "value": "" },
    { "name": "caption",   "value": "Let's play Cup Pong!" },
    { "name": "id",        "value": "<16-character game id>" },
    { "name": "player",    "value": "2" },
    { "name": "game",      "value": "beer" },
    { "name": "game_name", "value": "Cup Pong" },
    { "name": "seed",      "value": "947177914" },
    { "name": "mode",      "value": "n" },
    { "name": "style2",    "value": "0" },
    { "name": "num",       "value": "1" }
  ]
}
EOF
```

#### `POST app`

| Field | | |
|---|---|---|
| `chatGuid` | required | The chat to send into |
| `balloonBundleId` | required | The app's full bundle id, `com.apple.messages.MSMessageExtensionBalloonPlugin:<team>:<extension>`. The Polls bundle id is refused; see [below](#send-any-other-apps-message) |
| `url`, `json` or `fields` | one required | The payload, in whichever shape fits the app. If more than one is given, `url` wins, then `json` |
| `sessionId`, `caption`, `image`, `tempGuid`, `liveLayout` | optional | As on `game-pigeon` |
| `appName`, `appId`, `summary` | optional | The app's display name, its App Store id and the balloon's summary line |

#### The reply

Both sends answer with the message they wrote, the same object `GET /api/v1/message/:guid`
returns, plus two keys of their own:

```jsonc
{ "status": 200, "message": "Success", "data": {
  "guid": "…",
  "balloonBundleId": "com.apple.messages.MSMessageExtensionBalloonPlugin:EWFNLB79LQ:com.gamerdelights.gamepigeon.ext",
  // …the rest of the message…
  "tempGuid": "5D1F0C3A-8B7E-4F2A-9C61-0E4B7A2D9F13",
  "appPayload": { "session_id": "…", "url": "data:?ver=52&data=…", "game_pigeon": { … } }
} }
```

`appPayload` is the object [`GET app/:guid`](#read-any-app-message) answers. Keep
`appPayload.session_id`: it is the `sessionId` every later move in this game sends.

#### What is refused

Each of these is a `400` naming the problem, before anything reaches Messages:

| Request | Refused because |
|---|---|
| `game-pigeon` with no `fields`, or an entry with no `name` | There is nothing to send |
| `app` with none of `url`, `json` or `fields` | There is no payload |
| `app` with the Polls bundle id | It cannot render; use `POST /api/v2/message/poll` |
| A `sessionId` that is not a UUID | Messages would start a new session silently; omit it to start one on purpose |
| An `image` that is not base64, is empty, is not a JPEG, PNG or HEIC, or is over 4 MB | Send a thumbnail |
| A `tempGuid` already in flight | It is a duplicate of a send still running |
| `GET app/:guid` on a message that is not an app balloon | The route says which kind of balloon it is and where to read it instead |

### Read any app message

```http
GET /api/v2/message/app/:guid
```

```json
{ "status": 200, "data": {
  "guid": "…",
  "balloon_bundle_id": "com.apple.messages.MSMessageExtensionBalloonPlugin:EWFNLB79LQ:com.gamerdelights.gamepigeon.ext",
  "app_name": "GamePigeon",
  "app_id": 1124197642,
  "session_id": "2B62987D-…",
  "caption": "Let's play Cup Pong!",
  "summary": "Cup Pong",
  "url": "data:?ver=45&data=…",
  "game_pigeon": {
    "version": 45,
    "game": "beer",
    "game_id": "NlHyspTMBsictrrI",
    "fields": [ { "name": "sender", "value": "…" }, { "name": "player", "value": "2" } ]
  }
} }
```

Works for **any iMessage app**, not just Game Pigeon; the `game_pigeon` block appears only when
the bundle id says so. `url` is always the raw payload, so a client that understands an app this
server has never heard of can work from that alone.

Tested against every balloon type on the development Mac:

| Balloon | Reads? |
|---|---|
| Polls, Photos, Find My, Apple Pay, Game Center (Apple's own iMessage apps) | yes |
| Game Pigeon, OpenTable, YouTube, third-party poll apps | yes |
| Rich links (`com.apple.messages.URLBalloonProvider`) | **no** |
| Handwriting, Digital Touch | **no** |

The rule is the bundle id: anything with `MSMessageExtensionBalloonPlugin` in it is an iMessage
app and carries an `MSMessage` archive, which is what this route reads. The three that fail are
Apple's built-in balloon *providers*, which are not apps and have their own formats: a rich
link is an archived `RichLink`/`LPLinkMetadata`, and Digital Touch and handwriting are not even
property lists. The route says which case it hit and points at the alternative: rich-link
metadata already comes back from the ordinary read routes with `?with=payloadData`, and
handwriting and Digital Touch render through `GET /message/:guid/embedded-media`.

The payload URL is whatever the app chose, and it is not always a `data:` URL: Photos sends an
iCloud share link, YouTube a watch URL, Find My its own `?FindMyMessagePayloadVersion…` string.
Do not assume a scheme.

`fields` is an ordered list rather than an object on purpose: a query string may repeat a name,
and some games care about order. Build a map from it if you would rather have one.

`payload_json` and `payload_fields` are the same convenience going the other way, for apps that
are not Game Pigeon: whichever one the payload decodes as is present, and both are absent when
it is a plain link or a format this server does not recognise. They are suppressed for Game
Pigeon, whose outer query is only `ver` and the scrambled blob: `game_pigeon` is the real
answer there and showing both would invite reading the wrong one.

The read doesn't say whether the balloon used a live layout. Every Game Pigeon payload at
format 50 or later does (§ 6), so a client mirroring the sender's layout on a reply can send
one live.

### The same object on every message, without a second request

A client rendering a conversation should not have to fetch `app/:guid` once per balloon to
learn the session and the URL. So the object above also rides on the message itself, under
`appPayload`, on every `MSMessageExtensionBalloonPlugin` row and on nothing else:

| Where | When |
|---|---|
| `POST /message/query`, `GET /message/:guid`, `GET /chat/:guid/message` | only with `appPayload` in `with` |
| The reply to `POST message/app`, `message/game-pigeon` and the poll sends | always |
| The socket's `new-message`, `updated-message` and `message-send-error` | always |
| FCM, webhooks and the other notification transports | never |

The send reply is the one that matters most: when a client omits `sessionId` on an invite, the
server mints the session, and `appPayload.session_id` on the reply is how the client learns it
before anyone answers. Notifications are left out because FCM's 4 KB cap is already spent on the
chat roster, and a push only wakes a client that then reads the message anyway.

It is the same archive as `payloadData`, decoded. `payloadData` is still there for a client that
asks for it, as the raw `NSKeyedArchiver` graph every reference in which is a `{"UID": n}` to be
followed by hand.

### Matching a send to its placeholder

Every app send takes `tempGuid`, as `message/text` and `message/multipart` do. It comes back on
the reply and on a `new-message` that the send emits as soon as the row exists, so a client can
replace the balloon it drew optimistically instead of drawing a second one when the chat.db
watcher's plain `new-message` arrives first. It is also the deduplication key: a second send
under a `tempGuid` still in flight is refused rather than sent twice.

### Send a Game Pigeon message

The request is in [Calling it](#post-game-pigeon). The server scrambles the fields, wraps them
in the envelope and sends. Override `teamId` only if you are ever talking to a
differently-signed build of the app.

**`sessionId` is how a game stays one game.** Omit it on an invite and the server mints one;
include the session from the message you are answering on every reply. Game Pigeon's own `id`
field does its own threading, but the session is what Messages uses to group the balloons.

#### A later turn is a session update, and a live balloon draws the game

Two things a phone does on every turn after the first that a bare payload does not, both
measured by comparing the rows a phone wrote against the rows this server wrote, and both
done for you by `sessionId` and `liveLayout`.

**The link.** Messages threads an app's turns through the association columns. Every turn
after the first is sent with `associated_message_type` 2 and the **first turn's** GUID in
`associated_message_guid`; when it arrives, Messages on every device rewrites the turn it
supersedes to type 3: the first turn pointing at itself, a later turn keeping its pointer to
the first. Only the newest turn is type 2. The pointer is always to the first turn, never the
previous one: a poll's fourth vote names the poll, not the third vote. A turn sent without
the link is a balloon of its own, so the recipient's transcript shows one bubble per move
instead of one game, and their reply comes back unlinked too.

You never name the message. When `sessionId` is a session the chat already holds a balloon
for, the server finds the first turn (the newest 200 balloons of that app in that chat are
decoded, since nothing but the archive names a session) and sends the turn as an update to
it. A first turn, or a session nobody in the chat has seen, goes out unlinked, which is what
a first turn is. The link is what the thread already names where it names anything, so a
first turn deleted on this Mac is still what a new turn points at.

**The rewrite reaches you as an event.** When the type-3 rewrite lands on this Mac, which it
does for a turn this server sends as well as for one a phone sends, the superseded turn is
announced as an `updated-message` carrying `associatedMessageType: 3`. Nothing else in that
row changes, so this is the one signal that the turn is now superseded; a client drawing a
session as one balloon should hide it on that event and keep drawing the type-2 one.

**The live layout.** `liveLayout: true` writes `liveLayoutInfo` into the archive, the second
archive described in [the envelope](#2-the-envelope-every-imessage-app-is-the-same-shape).
Every message a current Game Pigeon sends carries it; without it the recipient's device
draws the template (the caption and the icon) rather than the game. It is a flag rather than
the default because this route sends for any app, and only an app that ships a live layout
should be told it has one. The template still travels beside it, so pass a `caption`.

#### Send a COMPLETE field set, or the recipient is told to update the app

This is the failure that will cost you an afternoon, because it does not look like a payload
problem. A too-short field set arrives, renders as a Game Pigeon balloon, and on tapping it
the recipient is told:

> You need to update to the latest version of GamePigeon

Nothing is wrong with the version. The app cannot parse the payload and says the most likely
reason it knows for that, which is not the actual one.

Measured. Two messages were sent to the same person minutes apart. The one that WORKED
(he opened it, played a move and the reply came back and decoded) carried 15 fields, copied
from a real Cup Pong invite. The one that produced the update message carried three:

| | fields | result |
|---|---|---|
| Cup Pong, copied from a genuine invite | 15 of 17 | played, and the reply came back |
| 8 Ball, `game` + `id` + `player` only | 3 of 20 | "You need to update…" |

Every genuine payload seen (two games, four years of app versions, invites and moves)
carries all of these:

```
sender  version  tver  ios  game  id  player  player2  seed  mode  num  build  avatar2
```

`version` and `tver` are the ones that most plausibly produce that particular message: with
no `version` at all the app reads nothing where it expects a format number. `seed` matters
just as much for play: it is what makes both devices rack the balls or place the cups the
same way, and a game will have its own required fields on top (8 Ball adds `v2`–`v5` and
`game_name`; Cup Pong adds `style2`).

**The server fills in four of them, and no more.** `sender`, `version`, `tver` and `ios` are
not game state: they identify the install, the sending OS and the payload format, and a
client has no way to know the right value for any of them. So `POST game-pigeon` prepends
them when you leave them out:

```jsonc
// what you send
"fields": [ {"game": "beer"}, {"id": "…"}, {"player": "2"} ]

// what goes on the wire
sender=<this server's UUID>&version=5&tver=5&ios=26.5.2&game=beer&id=…&player=2
```

**On an invite, `player2` is the sender.** Every genuine invite carries `player2` equal to
`sender`, and a move carries the opponent's. The server does not fill `player2` in, and it
does not report its `sender` on its own. A client that has sent a Game Pigeon message before
can read `sender` off that message's fields. Before its first one, it has no way to fill
`player2` in correctly.

`build` and `avatar2` are on every genuine payload too, and the server fills in neither. The
Cup Pong invite that was played went out without both, so neither is needed to play.

### Where the sender comes from

**Derived, not stored.** It is a hash of the Mac's `IOPlatformUUID`, so the same machine
produces the same answer forever and two machines cannot collide, with no row to write, back
up, migrate or reset. The server keeps no Game Pigeon state at all.

It is **42 characters**: a UUID plus six alphanumerics, because that is what every genuine
payload carries across two games, five app versions and both directions. A bare
36-character UUID is a length Game Pigeon has never sent.

The hash is one-way, so nothing about the machine goes on the wire: it is exactly as
identifying as a random UUID would have been, and no more.

**What it identifies is the INSTALL, not the person.** Measured across every Game Pigeon
message on the development Mac:

- One correspondent sent two games two months apart in 2020: identical `sender`.
- Another sent Cup Pong and 8 Ball forty-five minutes apart today: identical `sender`.
- But that same person, from the same address in 2021, has a completely different one. So
  does a second correspondent between 2021 and 2022. A new phone or a reinstall gets a new
  identifier.

It is therefore **not an Apple ID, an iCloud address or anything derived from one**: the
same account produces different values over time. The decisive evidence is our own: this server **made its identifier up
at random**, and Game Pigeon accepted it, stored it, and echoed it back as `player2` in the
reply. Nothing validates it against Apple or against anything else.

Practically that means it is a stable pseudonym. It carries no account information, but a
recipient can tell that two games came from the same server: exactly as they could from a
real install. Because it is derived from the machine rather than
stored, there is nothing to clear: it changes only if the Mac does. `ios` is the Mac's own version. `version` defaults to `5`, which is what
every genuine INVITE carries: **a reply must send its own**, echoing the value it is
answering. Moves do not agree with each other: a Cup Pong move carried `version=0` where an
8 Ball move carried `5`, so there is no rule to infer and the server does not try. Anything
you supply yourself is left exactly as you sent it, value and position, so echoing works.

Everything else is still yours. The server does not model games: that is what lets an
unknown Game Pigeon game work without a server change, so `seed`, `mode`, `num`, `player2`
and whatever the game itself needs are not filled in, and a payload without them will still
fail. The reliable way to build an invite is to **capture a real one from the game you want
and vary it**: `GET app/:guid` on any invite in the user's history hands you the complete
field list, in order, ready to edit.

#### The balloon's artwork comes from a message the app itself sent

Apple's payloads carry `ai`, the balloon artwork. Ours did not, and the consequence was
one-sided: the recipient (who has Game Pigeon installed) saw the app icon, while the
SENDING Mac, which does not have it, drew a bare balloon. A device with the extension falls
back to the installed app's icon; a device without one has nothing to fall back to.

The tempting conclusion was that `ai` is therefore cosmetic, and it is not. Our Polls
messages carry no `ai` either and render perfectly, which suggested the field was ignored:
but Polls is built into macOS, so the extension *is* installed and the system supplies the
presentation. The two cases were confounded. Sending a Game Pigeon balloon **with** `ai`
settled it: the icon appears locally.

There is nowhere to get that artwork except from the app itself, since a Mac generally has no
third-party iMessage app installed: Game Pigeon ships iOS-only. But it is already here: every
message the app has sent this Mac carries its `ai`, and it is the same 96×72 JPEG for Cup Pong
and 8 Ball, so it is app-level rather than per-game. `MessageRepository.balloonIcon(bundleID:)`
reads the most recent one and `sendAppMessage` attaches it.

Read on demand rather than cached: one indexed lookup on a send, against holding another
app's artwork in a store that would then need invalidating, and best effort throughout: a
Mac that has never received a message from that app gets no icon, which is the honest answer,
and a failed lookup costs an icon rather than a send.

#### The balloon's image is an attachment, and the client draws it

`ai` is the app's icon, on every Game Pigeon message. The picture a template layout shows (the
board, an invite card) is something else, it is optional (most genuine Game Pigeon messages
here carry none), and it does not live in the archive at all. Measured on a genuine Game
Pigeon message that has one:

- the image is an ordinary attachment joined to the balloon message: a 30 KB HEIC,
  `hide_attachment = 1`, so it draws inside the balloon rather than below it;
- the body is an attachment run (`U+FFFC` carrying `__kIMFileTransferGUIDAttributeName`) and a
  `__kIMBreadcrumbTextMarkerAttributeName`, with the `text` column null;
- the archive is unchanged: a template layout whose `userInfo` fills `caption` and nothing else.

So `image` on `POST message/app` and `message/game-pigeon` takes the picture as base64 (a
`data:image/…;base64,` prefix is accepted), checks it is a JPEG, PNG or HEIC by its bytes,
refuses one over 4 MB, and writes it into Messages' container. Only the sender can draw it,
which is why the server takes it rather than making one: what a board looks like is the
game's business.

**Don't promise the recipient sees the image.** An 8 Ball invite sent with an image was
delivered to a phone with Game Pigeon installed, and the phone drew Game Pigeon's own board
and "YOUR MOVE.", not the attached picture.

**The helper sends a balloon with an image through ChatKit, not as a hand-built message.**
Measured on macOS 27, both ways:

| How it was built | Result |
|---|---|
| `IMMessage` with the transfer in `fileTransferGUIDs` and no attachment run | 200 from the server, then `error = 34`, transfer state 6, never delivered |
| `CKBrowserItemPayload` (data, bundle id, image) through `compositionWithShelfPluginPayload:` | sent and delivered, transfer state 5, `hide_attachment = 1`, body as above |

A transfer only the GUID list names is never uploaded. The composition writes the breadcrumb
body and decides the hidden flag itself, which is what makes the second row match a genuine
one. It needs no extension installed. A plain `IMPluginPayload` is refused there: the
composition calls a ChatKit category method only `CKBrowserItemPayload` has. A balloon with no
image keeps the hand-built message, which has always delivered.

Messages re-encodes the image on the way in (39,028 bytes sent, 38,627 stored), so compare
the type and the flags, never the byte count. `LiveAppMessageSendTests` is the check, gated on
`BB_LIVE_SERVER_URL`, `BB_LIVE_SERVER_PASSWORD` and `BB_LIVE_SEND_GUID`.

#### A MOVE cannot be composed by this server, and that is settled

An invite is a payload. A **move is a physics result**, and the difference was measured by
sending one and asking the recipient what he saw.

The move went out correctly as an envelope: right game `id`, `num` incremented, roles
flipped, threaded onto the same `MSSession`. Its `replay` carried his own ball state back
verbatim with only the shot parameters (`d`, `p`) changed. What he reported:

> It's weird I saw a ball go in but you have no score
>
> Oh wait the entire end state is totally wrong

Both halves are explained by the same fact:

- **The shot parameters drive an animation.** The app happily replayed a shot from `d` and
  `p` (a ball went in on screen) so those are inputs it acts on.
- **`balls:` is the AUTHORITATIVE outcome, computed by the sender.** 31 entries of eight
  values, position and velocity per ball. Ours said the table was exactly as he had left it,
  which contradicted the animation it had just drawn. Hence "the entire end state is totally
  wrong".
- **8 Ball carries no score field at all**: checked across every 8 Ball payload, invites
  and moves: there is none. The score is *derived* from which balls are pocketed in `balls:`.
  Echoing his state meant none of ours were down, so "you have no score". (Cup Pong is
  different again: its moves carry `score1`, `score2`, `skip_score1`, `skip_score2`,
  `round`, `seed` and `seed2`: another reminder that two games do not agree.)

So composing a move means simulating the game: running the shot and computing where 31 balls
come to rest. That is exactly the modelling this server does not do, and this is the
measurement that says it should not start: there is no shortcut where the app recomputes
the result for you. **A client that wants to play must simulate the game itself**; the server
carries the payload, threads the session, and fills in identity.

Reading moves is unaffected and works: `GET app/:guid` decodes the whole `replay`, so a
client that does model the game has everything it needs.

### Send any other app's message

```http
POST /api/v2/message/app
{ "chatGuid": "…", "balloonBundleId": "…",
  "appName": "…", "appId": 123, "sessionId": "…", "caption": "…", "summary": "…",
  "liveLayout": true,
  <one of: "url" | "json" | "fields"> }
```

The generic version. You do **not** have to build the payload URL yourself unless you want to:
give the server the payload in whichever of these shapes fits the app:

| Field | Sends | Use it for |
|---|---|---|
| `"json": { … }` | `data:,<base64 of the JSON>` | apps whose payload is JSON |
| `"fields": [{"name","value"}]` | `data:?a=1&b=2` | apps whose payload is a query string |
| `"url": "…"` | exactly what you gave | everything else: an https link, a media-type `data:` URL, anything |

`fields` also accepts a plain object when order does not matter. The reverse holds on the read
side: `GET app/:guid` adds `payload_json` when the payload decodes as base64 JSON, or
`payload_fields` when it is a query string, alongside the raw `url`. So for the two common
shapes a client never has to base64 or percent-encode anything in either direction.

Measured: a `json` payload sent and read back with its structure intact, and a `fields`
payload round-tripping including a value with a space and an empty one.

Nothing about this route is Game Pigeon-specific, so any iMessage app can be driven through it
once you know what that app expects in its payload.

**One balloon is refused: Polls.** `POST app` returns 400 for the
`…:com.apple.messages.Polls` bundle id and points at `POST /api/v2/message/poll` instead.

A poll sent from here is not a poll. A poll is a live balloon the Polls path builds on a real
`MSMessage` through ChatKit, with the vote and add-option flows only that path has; one sent
from here with a template layout arrived as a bare balloon reading "Sent a poll" with an "Add
Choice" button and **no options**, whatever its payload said. A well-formed poll payload is refused for exactly the same reason as a malformed
one; when the payload is *also* wrong, the error says which fields are missing as well, so a
client is not left fixing one problem and hitting the other.

Learned the expensive way. Two such balloons were sent into a real conversation while testing
this route's `json` and `fields` encoders, and they are still there: long past the unsend
window, so they cannot be taken back. Refusing is what stops that happening again.

---

## 5. Writing a client

The server has done its half when it hands you fields. Yours looks like this:

1. **Spot a game.** `balloonBundleId` ends `com.gamerdelights.gamepigeon.ext`. The decoded
   payload is the message's `appPayload`: always on a socket `new-message`, and on a read when
   you ask for it with `with=appPayload`. `GET /api/v2/message/app/:guid` reads one message.
2. **Group by game, and draw one balloon per game.** Use the `id` field, not the message
   guid: every move in a game repeats it. The `session_id` groups the same messages at the
   Messages level and is what you send back. Messages itself links the turns through
   `associatedMessageType` and `associatedMessageGuid`: the newest turn is type 2 pointing at
   the game's first message, every superseded turn is type 3, and a first turn with no reply
   yet is type 0. Draw the type-2 (or lone type-0) turn and hide the type-3 ones; see
   [the session update](#a-later-turn-is-a-session-update-and-a-live-balloon-draws-the-game).
3. **Work out whose turn it is.** `player` against `player1`/`player2`, compared with your own
   account's identifier from `sender` on messages you sent.
4. **Hand the game to whatever plays it.** The server cannot compute a move (§ 4), so the
   payload goes to something that runs the game: a companion app such as OpenPigeon, or your
   own implementation. It gets `appPayload.url` (or the decoded `fields`) and the session, and
   produces the next payload. That is the complete state, not a delta, in whatever shape that
   game uses.
5. **Send the move on its behalf** with `POST game-pigeon`: the new `fields`, the same
   `sessionId`, `liveLayout: true`, a `caption`, an `image` if the game drew one, and a
   `tempGuid`. The `sessionId` is what makes it a turn in the game rather than a new balloon:
   the server links it to the game's first message for you, and the live layout is what a
   current Game Pigeon sends. Draw the balloon at once under that `tempGuid` and replace it
   when the reply, or the socket `new-message` carrying the same `tempGuid`, arrives.
6. **Hide the turn it replaced.** When a turn lands, Messages rewrites the one it superseded to
   type 3, and the server announces that as an `updated-message` whose `associatedMessageType`
   is now 3 (the only change in that row). Hide that balloon, on your own sends as well as the
   other player's. An invite you sent gets the same rewrite when their first move arrives.
7. **Be version-tolerant.** Echo back the `version` you received rather than assuming; a thread
   can span several as people update their apps.

If you only want to *show* that a game happened rather than play it, `caption` and `game` are
enough for a sensible bubble, and you can skip the rest.

---

## 6. What has actually been tested

- **Reading:** all eight real Game Pigeon messages on the development Mac, spanning Cup Pong,
  Crazy 8, 8 Ball and 8 Ball+, and format versions 42, 45, 48, 49 and 50. Every one decoded to
  a complete field list.
- **Writing:** a Cup Pong invite sent from the API landed with the right bundle id, a 1.2 KB
  payload, and `is_delivered = 1`, and read back through our own route with its fields intact.
- **Playing, end to end, in two different games.** Someone opened a Cup Pong invite on their
  phone, played, and the reply arrived and decoded here: `num = 2`, `round = 1`, both
  scores, a `replay` field holding the shot. Then an 8 Ball invite built from a genuine 2021
  payload did the same: his move came back carrying the game `id` this server minted, a
  `replay` with the shot physics (`d:12.537708&x:0.000000&y:28.600000&p:2000.000000&balls:…`),
  and `player2` set to **this server's own `sender`**: so the identity the server mints is
  read by the app and echoed back. A game sent from here is a real, playable game.
- **What a MOVE looks like** differs from an invite and from game to game. Both moves add
  `player1`, `avatar1` and `replay`, and drop `caption`, `start` and `game_name`. Cup Pong's
  carried `seed`, `round` and four score fields; 8 Ball's carried none of those. This is why
  the server does not model games: two games one release apart do not agree on their fields.
- **The codec:** round-trips at every length tested, and matches vectors computed by a separate
  implementation of the same algorithm.
- **A send with an image, on macOS 27.0.1:** an 8 Ball invite with a JPEG went out through
  ChatKit and was delivered. The image was stored hidden, the transfer finished, and the body
  matched a genuine one. The reply carried the `tempGuid` and an `appPayload` with the session
  the server minted.
- **`with=appPayload` on a v1 read:** `GET /api/v1/message/:guid` decoded a genuine Archery
  invite received from a phone, session and fields included.
- **The session link and the live layout, against `chat.db`:** every genuine Game Pigeon
  payload at format 50 or 52 carries `liveLayoutInfo` (six of six) and none at 49 or below
  does; every Game Pigeon game and every poll with more than one turn points its later turns
  at the first, and the first turn is rewritten to type 3 on this Mac when a reply arrives,
  including a first turn this server sent. A move this server sent without the link, and the
  phone's reply to it, both sat at type 0, which is the symptom the link fixes.
- **Three linked turns sent live, on macOS 27.0.1:** a first turn with `liveLayout`, then two
  turns naming its `sessionId`, the third with an image. Both later turns landed with
  `associated_message_type` 2 and the first turn's GUID, range `{0, -1}` as a phone writes,
  `liveLayoutInfo` in every archive, `is_delivered = 1`, and the image joined as a hidden
  attachment. Messages rewrote the first turn to type 3 pointing at itself and the second to
  type 3 still pointing at the first, and the server announced each rewrite as an
  `updated-message` whose changed field was the association.
