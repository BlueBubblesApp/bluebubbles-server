# Game Pigeon, and iMessage apps in general

How Game Pigeon messages are put together, what this server does with them, and what a client
has to do to actually play a game. Measured on macOS 26.5.2 against real Game Pigeon threads —
four different games across five format versions.

The short version: **the server reads and writes the payloads, the client plays the games.**
That split is not a design preference, it is forced — see § 1.

---

## 1. Why the Mac cannot play

Game Pigeon is an iOS-only iMessage app. There is no Mac version, so the extension is not
installed on the server's Mac and never will be. Messages on macOS shows a received game as a
plain fallback bubble ("Let's play Cup Pong!") with no board and no controls.

So the Mac cannot render a game, cannot compute a move, and cannot be asked to. What it *can*
do is read the payload out of a message and put a new one back on the wire, which it turns out
is all a client needs — the game state travels in the message itself.

This server therefore offers a **flexible pass-through**: it decodes the payload into fields
and sends fields back. It does not know what "8 Ball" is, and deliberately so. There are two
dozen Game Pigeon games and they share nothing but the envelope.

---

## 2. The envelope: every iMessage app is the same shape

Game Pigeon, Polls, and any third-party iMessage app all send the same structure. The message
row carries:

- `balloon_bundle_id` — `com.apple.messages.MSMessageExtensionBalloonPlugin:<team>:<bundle>`.
  Game Pigeon's is `…:EWFNLB79LQ:com.gamerdelights.gamepigeon.ext`. The team id belongs to the
  developer, so match on the **suffix**, not the whole string.
- `payload_data` — an `NSKeyedArchiver` archive of the `MSMessage` the extension built.
- empty `text`.

Unarchived, that payload is a dictionary:

| Key | What it is |
|---|---|
| `URL` | the app's own payload — everything game-specific is in here |
| `an` | app name, e.g. `GamePigeon` |
| `appid` | App Store id — Game Pigeon is `1124197642` |
| `sessionIdentifier` | `MSSession` UUID, shared by every message of one game |
| `ldtext` | fallback summary line |
| `layoutClass` / `userInfo` | the template layout, whose `caption` is the human-readable line |
| `ai` | the app's icon, a few KB of JPEG |

`AppMessagePayload` reads and writes this, and it is not Game Pigeon-specific — the poll code
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

`ver` is Game Pigeon's format version — 42, 45, 48, 49, 50 and 52 have all been seen in the
wild, and they coexist because it is whatever version the sender's app was.

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
| `game` | the game's internal name — `beer` is Cup Pong, `pool` is 8 Ball, `pool3` is 8 Ball+, `crazy` is Crazy 8 |
| `game_name` | its display name, on invites |
| `id` | Game Pigeon's own game id, stable for the whole game, distinct from the `MSSession` UUID |
| `player`, `player1`, `player2` | whose turn it is, and the two player ids |
| `sender` | who sent this message — a UUID with six extra characters appended |
| `caption` | the line shown on the bubble |
| `seed` | the game's RNG seed, so both sides simulate the same thing |
| `avatar1`, `avatar2` | the pigeon avatars, as `body,5\|eyes,7\|mouth,5\|…` |
| `start` | present and empty on an invite |
| `replay` | the move itself. 8 Ball's is 2.4 KB of physics (`&d:…&x:…&y:…&balls:#…`) |

**Do not build a client around that table.** Every game puts what it likes in there — a word
game's fields look nothing like pool's — which is exactly why the API hands back a list of
name/value pairs and stops.

---

## 4. The API

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
  "payload_json": null,
  "payload_fields": null,
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
Apple's built-in balloon *providers*, which are not apps and have their own formats — a rich
link is an archived `RichLink`/`LPLinkMetadata`, and Digital Touch and handwriting are not even
property lists. The route says which case it hit and points at the alternative: rich-link
metadata already comes back from the ordinary read routes with `?with=payloadData`, and
handwriting and Digital Touch render through `GET /message/:guid/embedded-media`.

The payload URL is whatever the app chose, and it is not always a `data:` URL — Photos sends an
iCloud share link, YouTube a watch URL, Find My its own `?FindMyMessagePayloadVersion…` string.
Do not assume a scheme.

`fields` is an ordered list rather than an object on purpose: a query string may repeat a name,
and some games care about order. Build a map from it if you would rather have one.

`payload_json` and `payload_fields` are the same convenience going the other way, for apps that
are not Game Pigeon: whichever one the payload decodes as is filled in, and both are null when
it is a plain link or a format this server does not recognise. They are suppressed for Game
Pigeon, whose outer query is only `ver` and the scrambled blob — `game_pigeon` is the real
answer there and showing both would invite reading the wrong one.

### Send a Game Pigeon message

```http
POST /api/v2/message/game-pigeon
{
  "chatGuid": "iMessage;-;+15551234567",
  "version": 45,
  "caption": "Let's play Cup Pong!",
  "sessionId": "2B62987D-…",
  "fields": [
    { "name": "sender",    "value": "<your install's UUID>" },
    { "name": "version",   "value": "5" },
    { "name": "tver",      "value": "5" },
    { "name": "ios",       "value": "26.5.2" },
    { "name": "start",     "value": "" },
    { "name": "caption",   "value": "Let's play Cup Pong!" },
    { "name": "id",        "value": "<16-character game id>" },
    { "name": "player",    "value": "2" },
    { "name": "player2",   "value": "<your install's UUID>" },
    { "name": "game",      "value": "beer" },
    { "name": "game_name", "value": "Cup Pong" },
    { "name": "seed",      "value": "947177914" },
    { "name": "mode",      "value": "n" },
    { "name": "style2",    "value": "0" },
    { "name": "num",       "value": "1" }
  ]
}
```

The server scrambles the fields, wraps them in the envelope and sends. `fields` may also be a
plain object when order does not matter. `version` defaults to 52, `teamId` to Game Pigeon's
own — override it if you are ever talking to a differently-signed build.

**`sessionId` is how a game stays one game.** Omit it on an invite and the server mints one;
include the session from the message you are answering on every reply. Game Pigeon's own `id`
field does its own threading, but the session is what Messages uses to group the balloons.

#### Send a COMPLETE field set, or the recipient is told to update the app

This is the failure that will cost you an afternoon, because it does not look like a payload
problem. A too-short field set arrives, renders as a Game Pigeon balloon, and on tapping it
the recipient is told:

> You need to update to the latest version of GamePigeon

Nothing is wrong with the version. The app cannot parse the payload and says the most likely
reason it knows for that, which is not the actual one.

Measured. Two messages were sent to the same person minutes apart. The one that WORKED —
he opened it, played a move and the reply came back and decoded — carried 15 fields, copied
from a real Cup Pong invite. The one that produced the update message carried three:

| | fields | result |
|---|---|---|
| Cup Pong, copied from a genuine invite | 15 of 17 | played, and the reply came back |
| 8 Ball, `game` + `id` + `player` only | 3 of 20 | "You need to update…" |

Every genuine payload seen — two games, four years of app versions, invites and moves —
carries all of these:

```
sender  version  tver  ios  game  id  player  player2  seed  mode  num  build  avatar2
```

`version` and `tver` are the ones that most plausibly produce that particular message: with
no `version` at all the app reads nothing where it expects a format number. `seed` matters
just as much for play — it is what makes both devices rack the balls or place the cups the
same way — and a game will have its own required fields on top (8 Ball adds `v2`–`v5` and
`game_name`; Cup Pong adds `style2`).

**The server fills in four of them, and no more.** `sender`, `version`, `tver` and `ios` are
not game state — they identify the install, the sending OS and the payload format — and a
client has no way to know the right value for any of them. So `POST game-pigeon` prepends
them when you leave them out:

```jsonc
// what you send
"fields": [ {"game": "beer"}, {"id": "…"}, {"player": "2"} ]

// what goes on the wire
sender=<this server's UUID>&version=5&tver=5&ios=26.5.2&game=beer&id=…&player=2
```

### Where the sender comes from

**Derived, not stored.** It is a hash of the Mac's `IOPlatformUUID`, so the same machine
produces the same answer forever and two machines cannot collide — with no row to write, back
up, migrate or reset. The server keeps no Game Pigeon state at all.

It is **42 characters**: a UUID plus six alphanumerics, because that is what every genuine
payload carries across two games, five app versions and both directions. What the suffix
means is unknown; a per-device salt and an install counter would both fit. A bare
36-character UUID is a length Game Pigeon has never sent.

The hash is one-way, so nothing about the machine goes on the wire — it is exactly as
identifying as a random UUID would have been, and no more.

**What it identifies is the INSTALL, not the person.** Measured across every Game Pigeon
message on the development Mac:

- One correspondent sent two games two months apart in 2020 — identical `sender`.
- Another sent Cup Pong and 8 Ball forty-five minutes apart today — identical `sender`.
- But that same person, from the same address in 2021, has a completely different one. So
  does a second correspondent between 2021 and 2022. A new phone or a reinstall gets a new
  identifier.

It is therefore **not an Apple ID, an iCloud address or anything derived from one** — the
same account produces different values over time, and different accounts on one device would
presumably share one. The decisive evidence is our own: this server **made its identifier up
at random**, and Game Pigeon accepted it, stored it, and echoed it back as `player2` in the
reply. Nothing validates it against Apple or against anything else.

Practically that means it is a stable pseudonym. It carries no account information, but a
recipient can tell that two games came from the same server — exactly as they could from a
real install. Because it is derived from the machine rather than
stored, there is nothing to clear — it changes only if the Mac does. `ios` is the Mac's own version. `version` defaults to `5`, which is what
every genuine INVITE carries — **a reply must send its own**, echoing the value it is
answering. Moves do not agree with each other: a Cup Pong move carried `version=0` where an
8 Ball move carried `5`, so there is no rule to infer and the server does not try. Anything
you supply yourself is left exactly as you sent it, value and position, so echoing works.

Everything else is still yours. The server does not model games — that is what lets an
unknown Game Pigeon game work without a server change — so `seed`, `mode`, `num`, `player2`
and whatever the game itself needs are not filled in, and a payload without them will still
fail. The reliable way to build an invite is to **capture a real one from the game you want
and vary it**: `GET app/:guid` on any invite in the user's history hands you the complete
field list, in order, ready to edit.

### Send any other app's message

```http
POST /api/v2/message/app
{ "chatGuid": "…", "balloonBundleId": "…",
  "appName": "…", "appId": 123, "sessionId": "…", "caption": "…", "summary": "…",
  <one of: "url" | "json" | "fields"> }
```

The generic version. You do **not** have to build the payload URL yourself unless you want to —
give the server the payload in whichever of these shapes fits the app:

| Field | Sends | Use it for |
|---|---|---|
| `"json": { … }` | `data:,<base64 of the JSON>` | apps whose payload is JSON |
| `"fields": [{"name","value"}]` | `data:?a=1&b=2` | apps whose payload is a query string |
| `"url": "…"` | exactly what you gave | everything else — an https link, a media-type `data:` URL, anything |

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

This is not a policy choice, it is that the route cannot do it. `AppMessagePayload.encode`
writes `layoutClass = MSMessageTemplateLayout`; a poll needs `MSMessageLiveLayout`, which
only the Polls path sets — on a real `MSMessage`, through ChatKit. So a poll sent from here
arrives as a bare balloon reading "Sent a poll" with an "Add Choice" button and **no
options**, whatever its payload says. A well-formed poll payload is refused for exactly the
same reason as a malformed one; when the payload is *also* wrong, the error says which fields
are missing as well, so a client is not left fixing one problem and hitting the other.

Learned the expensive way. Two such balloons were sent into a real conversation while testing
this route's `json` and `fields` encoders, and they are still there — long past the unsend
window, so they cannot be taken back. Refusing is what stops that happening again.

---

## 5. Writing a client

The server has done its half when it hands you fields. Yours looks like this:

1. **Spot a game.** `balloonBundleId` ends `com.gamerdelights.gamepigeon.ext`. Fetch
   `GET /message/app/:guid` for the decoded payload.
2. **Group by game.** Use the `id` field, not the message guid — every move in a game repeats
   it. The `session_id` groups the same messages at the Messages level and is what you send back.
3. **Work out whose turn it is.** `player` against `player1`/`player2`, compared with your own
   account's identifier from `sender` on messages you sent.
4. **Render and play.** This is all yours. The state you need is in `fields`, in whatever shape
   that game uses.
5. **Send a move** as a new Game Pigeon message with the same `id` and `sessionId`, `player`
   flipped, and whatever fields the game expects. Keep the fields you did not change: these
   payloads are full state, not deltas.
6. **Be version-tolerant.** Echo back the `version` you received rather than assuming; a thread
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
  phone, played, and the reply arrived and decoded here — `num = 2`, `round = 1`, both
  scores, a `replay` field holding the shot. Then an 8 Ball invite built from a genuine 2021
  payload did the same: his move came back carrying the game `id` this server minted, a
  `replay` with the shot physics (`d:12.537708&x:0.000000&y:28.600000&p:2000.000000&balls:…`),
  and `player2` set to **this server's own `sender`** — so the identity the server mints is
  read by the app and echoed back. A game sent from here is a real, playable game.
- **What a MOVE looks like** differs from an invite and from game to game. Both moves add
  `player1`, `avatar1` and `replay`, and drop `caption`, `start` and `game_name`. Cup Pong's
  carried `seed`, `round` and four score fields; 8 Ball's carried none of those. This is why
  the server does not model games: two games one release apart do not agree on their fields.
- **The codec:** round-trips at every length tested, and matches vectors computed by a separate
  implementation of the same algorithm.

## 7. Loose ends

- Our archive omits `ai`, the app icon, which Apple's carry. A receiving device presumably
  falls back to the installed app's icon; not confirmed.
- **`build` and `avatar2` are on every genuine payload and we send neither.** The Cup Pong
  invite that was actually played was missing both, so neither is required to play — but a
  short field set is what produces the "update to the latest version" message (§ 4), and
  these are the only two universal fields still unaccounted for. Worth sending, once we know
  what a valid `build` token looks like.
- **`player2` has to equal `sender` on an invite, and a client cannot know the sender.**
  Every genuine invite carries `player2 == sender`; a move carries the opponent's. The server
  owns `sender` and does not report it anywhere, so a client has no way to fill `player2` in
  correctly. Exposing the server's own identifier read-only would fix it without modelling
  any game — the 8 Ball test invite had to read it out of the settings table by hand.
- **The boilerplate is filled in now** (§ 4), but the rest of a valid payload is still the
  client's problem — `seed`, `mode`, `num` and the game's own fields. Whether the
  server should go further is a real question and the answer is probably no: past these four
  it would be modelling games.
- Nothing reads Game Pigeon *attachments* — some games send images alongside the payload.
- Game Pigeon is a third-party app and none of this is a supported interface. A future version
  could change the format; `ver` is the thing to watch.
