# Stickers

How stickers are stored on a Mac, how a client reads and adds them through this server, how
it sends one onto a message, and what it receives when someone else does.

Sections 1 to 3 are about the sticker **library**: the picker's contents. Section 4 is the
client integration guide: sending, reacting, and rendering the stickers that arrive, including
where a placed sticker sits. How the helper builds a sent sticker
inside Messages is a different subject and lives in
[`PRIVATE_API_SURFACE.md`](PRIVATE_API_SURFACE.md) § Stickers.

---

## 1. Where stickers live

Not in `chat.db`. There is a separate store:

```
~/Library/Group Containers/com.apple.stickersd.group/Stickers/stickers.stickerdb
```

It is a Core Data database with CloudKit mirroring, owned by `stickersd`, and it has exactly
two tables worth reading:

| Table | One row per | Notable |
| --- | --- | --- |
| `ZMANAGEDSTICKER` | sticker | identity, origin, dates, attribution |
| `ZMANAGEDREPRESENTATION` | rendition | **the image bytes, inline in `ZDATA`** |

That last point is the whole reason this feature is cheap: the images are *in the database*.
There is no separate asset directory to resolve, no iCloud fetch, no helper round trip. The
server opens the file read-only and the bytes are there.

So **all three read routes work on a Mac with no Private API helper at all.** They need Full
Disk Access (the same grant `chat.db` already requires) and nothing else.

### Two shelves

`ZMANAGEDSTICKER.ZTYPE` splits the store in two, and the API calls them shelves:

- **`saved`** (`ZTYPE = 1`): the sticker drawer. What the user made and kept. Syncs via iCloud.
- **`recent`** (`ZTYPE = 0`): recently used. Emoji and Memoji stickers *only* ever appear here.

The mapping was read off a live store rather than guessed. The giveaway is a sticker that is
on both shelves at once: this Mac holds one custom Live Sticker, and the store has two rows
for it:

```
Z_PK  ZTYPE  identifier    ZEXTERNALURI
5     1      AC20781C-…    sticker:///user/identifier/AC20781C-…
4     0      C229525C-…    sticker:///user/identifier/AC20781C-…
```

That is a `ZTYPE = 1` row whose own identifier is `AC20781C-…`, and a `ZTYPE = 0` row with a fresh
identifier whose external URI points *back* at the first. A donation to recents has exactly
that shape, so `1` is the original and `0` is the recent. It was then confirmed directly:
`POST /api/v2/sticker` produced a `ZTYPE = 0` row.

### Where a sticker came from

`ZEXTERNALURI` is the single most useful field on a sticker, because it says what the thing
actually is:

```
sticker:///emoji/identifier/😭                         an emoji sticker
sticker:///memoji/cow/cow_smiling_face_with_heart-…    a Memoji sticker
sticker:///user/identifier/<UUID>                      something the user made
```

The API parses that first path component for you and reports it as `kind`: `emoji`, `memoji`,
`user`, or `unknown` for a source Apple adds later. A client should branch on `kind` rather
than pattern-matching the URI itself: the emoji form ends in the literal emoji character,
which is easy to get wrong.

### Genmoji are stickers with a prompt

A Genmoji is a `user` sticker whose row carries a prompt (`ZSANITIZEDPROMPT`), usually on both
shelves, with renditions at 40, 64, 96, 160, 320 and 1024 pixels. They appear in the routes
below like any sticker, twice when they are on both shelves. `GET /api/v2/genmoji/library`
lists each one once, by the content identifier a sent Genmoji carries, and resizes its images;
`.claude/docs/api.md` describes it.

### Representations

A sticker has one or more renditions, and which ones depends on where it came from:

- A sticker **Messages made** has two: a full-size `com.apple.stickers.role.still` (usually
  HEIC, for example 900 × 712) and a small `com.apple.stickers.role.keyboard` PNG for the picker.
- An **emoji or Memoji** sticker has one, with an **empty** role string.

Every representation reports its `uti`, its `mime_type`, its pixel size and whether it is
`is_preferred`. The preferred one is what a download serves when no role is asked for.

---

## 2. What can and cannot be written

Reading is unrestricted. Writing is where it gets narrow, and the shape of the restriction is
worth stating plainly because it limits what a client can offer.

**Writing needs the helper.** The store's container is entitled to
`com.apple.stickersd.group`; this server is not. So the write runs inside Messages, through
the injected helper, like every other Private API call.

**The only write Messages exposes is a donation to recents:**

```objc
-[_STKMessagesObjCStoreFacade
    donateStickerToRecentsWithIdentifier:representations:stickerEffectEnum:
    externalURI:name:accessibilityName:metadata:attributionInfo:error:]
```

That is what Messages itself calls after sending a sticker. There is **no** "add to the saved
drawer" call on that facade, and that asymmetry is real rather than a gap in our research:
saved stickers are created by the Stickers extension lifting a subject out of a photo, which
is a UI flow with no API behind it.

**Removal is a different door.** `stickersd` removes rows on its own mach service, but only
for a process with Messages' private stickers entitlement, so it also runs in the helper. It is
what `DELETE /api/v2/genmoji/library/:id` uses; `PRIVATE_API_SURFACE.md` has the selector.

So `POST /api/v2/sticker` adds a **recent**. The response says `"shelf": "recent"`, and a
client should not promise the user anything else. The sticker is fully usable: it appears in
Messages' picker and in `GET /api/v2/sticker`, and its image can be sent like any other. It is
not in the saved drawer.

### Two things that cost real debugging

Both are recorded because they are the kind of thing that looks like a bug in your own code:

1. **The store does not file the sticker under the identifier you give it.** It mints its own
   row identifier and records the one it was given as the `ZEXTERNALURI`. The first version of
   the save route answered with the donation's identifier and every read of it 404'd. The
   route now looks the row up by external URI, so the `identifier` it returns is one the read
   routes accept.

2. **`STKStickerRepresentation` cannot be constructed.** Its `-init` is a Swift *unimplemented
   initializer*: it loads the strings `"Stickers.Representation"` and `"init()"` and executes
   `brk #0x1`. Calling it does not fail, it traps, and it took Messages down with
   `EXC_BREAKPOINT`. The class the donation actually wants is
   `_STKStickerUIStickerRepresentation`, which has a real initializer
   (`-initWithData:type:size:role:`). That was read out of the facade's own disassembly, where
   it fetches that type's metadata before touching anything else.

The UTI and pixel size are read from the image bytes with ImageIO rather than taken from the
filename, so a PNG named `.heic` does not produce a row that lies about either.

---

## 3. The REST API

Four routes, under `/api/v2/sticker`. All of them are mounted on every server; there is no
setting to turn v2 on.

**Mounted is not the same as available: every sticker route needs the Pro tier.** The
`stickerLibrary` and `stickers` groups in `RouteTable` both declare `minimumTier: .pro`, the
reads included, even though the reads need no helper. A server without that tier answers
`402` with `error.type` `Payment Required`, before the request reaches the store. Section 4
says how a client finds this out first.

### `GET /api/v2/sticker`: list the library

| Query | Default | Meaning |
| --- | --- | --- |
| `source` | `all` | `saved`, `recent`, or `all`. A comma-separated pair means `all`. |
| `limit` | `100` | Max 1000. |
| `offset` | `0` | For paging. |

Sorted newest first, by the store's own `library_index`.

**No image bytes here, deliberately.** The store keeps images inline in the same table, and a
page of six stickers is already a couple of megabytes. The list is metadata; `:id/image` is
the download.

`metadata` reports both shelf totals *whatever `source` asked for*, so one request is enough
to render both sections and page either:

```json
{
  "status": 200,
  "metadata": { "count": 6, "limit": 100, "offset": 0, "total": 6, "saved": 1, "recent": 5 },
  "data": [ { "identifier": "7608FF1D-…", "shelf": "recent", "kind": "memoji", … } ]
}
```

### `GET /api/v2/sticker/:id`: one sticker

The same object, on its own. `:id` accepts the dashed UUID the API reports; bare hex works
too. A malformed identifier is a 404, not a 500.

### `GET /api/v2/sticker/:id/image`: the bytes

Answers the image itself, with the representation's real `Content-Type` (`image/png`,
`image/heic`).

`?role=` picks the representation. `still` and `keyboard` are shorthands for the long
reverse-DNS role strings, so a client need not hard-code them; the full role string off a
representation works as well. Omitted serves the preferred one.

**A role this sticker does not have falls back to preferred rather than 404ing.** "This
sticker has no keyboard thumbnail" is not "there is no such sticker", and a client asking for
a thumbnail wants an image either way.

### `POST /api/v2/sticker`: add one

`multipart/form-data`, the same form as the attachment routes:

| Field | | |
| --- | --- | --- |
| `attachment` | file, **required** | The image. PNG and HEIC are what Messages writes. |
| `name` | string | The sticker's own name. Messages usually leaves this empty. |
| `accessibilityName` | string | What VoiceOver reads, and the only searchable text the store keeps. |

A JSON body naming a `filePath` from an earlier `POST /api/v1/attachment/upload` is accepted
too.

```bash
curl -X POST "http://localhost:1234/api/v2/sticker?password=…" \
  -F "attachment=@sticker.png;type=image/png" \
  --form-string "accessibilityName=teal circle"
```

Answers with the sticker as the store now holds it (read back, not echoed) so the
`identifier` is immediately usable and the representation carries the UTI and size the store
derived from the bytes.

Note that `name` here means the **sticker's** name. On every other file route `name` renames
the uploaded file, because there it means "what the recipient sees"; on this one the file
keeps its own filename.

---

## 4. Integrating a client

This section is the order a client works in: find out what the server can do, show the
library, send, react, add, and render what arrives. Every route below is v2, needs the Pro tier
(section 3), and is described in the OpenAPI document at
[`docs/api/openapi.json`](api/openapi.json).

### Find out what this server can do before offering anything

A client decides which sticker features to show from three answers, all of which it can get
before the user taps anything:

| Question | Where to ask | What it gates |
| --- | --- | --- |
| Is the Pro tier held? | `GET /api/v2/server/subscription`, field `tier` | Every sticker route |
| Is the helper connected? | `GET /api/v1/server/info`, fields `private_api` and `helper_connected` | Sending, reacting, adding to the library |
| Is this Mac on macOS 15 or later? | `GET /api/v1/server/info`, field `os_version` | Reacting with a sticker |

The subscription route needs the `server:admin` scope. A client that holds a narrower token
can't ask it, so it has to treat a `402` as the answer instead. The `402` body's `data` carries
`required_tier`, `current_tier`, `reason` and `purchase_url`, which is enough to explain the
refusal without a second request; `PaymentRequired` in `HTTPErrors.swift` is the shape.

**Browsing the library needs no helper.** If the tier is held and the helper is not
connected, offer the picker read-only. Hide send, react and add rather than letting them fail:
a route that needs the helper and does not have it answers with `error.type` `iMessage Error`.

### Show the user's library

Use these routes in this order:

1. Call `GET /api/v2/sticker` once. `metadata.saved` and `metadata.recent` carry both shelf
   totals whatever `source` asked for, so one request is enough to lay out both sections.
2. Page each shelf with `source`, `limit` and `offset`.
3. Fetch each tile's image from `GET /api/v2/sticker/:id/image?role=keyboard`. The list carries
   no image bytes.
4. Fetch `?role=still` only when the user opens or sends a sticker.

These rules keep the picker matching what Messages shows:

- **Filter on `accessibility_name`.** It is the only searchable text the store keeps, and it
  is what Messages' own picker search matches. `name` is usually null.
- **Sort by `library_index`, not by date.** It is the store's own ordering and it is what the
  picker shows. It does not always agree with `last_used_at`.
- **Use `kind` to group the picker.** Emoji, Memoji and user stickers want different
  treatment, and `kind` saves parsing the URI.
- **Ask for `?role=keyboard` in a grid.** The `still` representation can be 400 KB; the
  keyboard preview is around 15 KB and is what the thumbnail is for.
- **An empty library is not an error.** A Mac that has never had a sticker has no store file
  at all, and one without Full Disk Access cannot read it. Both answer `200` with an empty
  array and a `metadata.reason` saying which, so a client should render "no stickers" and
  surface the reason rather than treating it as a failure.

### Send a sticker onto a message

`POST /api/v2/message/sticker` places an image over one part of a message, the way dragging a
sticker onto a bubble does in Messages. It needs the helper and the `messages:write` scope.

**There is no send-by-identifier.** The route takes a file, so a sticker from the library is
sent by downloading `GET /api/v2/sticker/:id/image?role=still` and uploading those bytes. Any
other image works the same way: the route doesn't require the file to be in the library.

The body is `multipart/form-data`, with the image under `attachment` and every other field as
a string. A JSON body naming a `filePath` from an earlier `POST /api/v1/attachment/upload` is
accepted instead of the file part.

| Field | | Meaning |
| --- | --- | --- |
| `attachment` | file, **required** | The image. PNG and HEIC are what Messages writes. |
| `chatGuid` | string, **required** | The chat the target message is in. |
| `selectedMessageGuid` | string, **required** | The message to place the sticker on. |
| `partIndex` | integer | Which part of that message. Defaults to `0`. |
| `xScalar`, `yScalar` | number | Where the sticker's centre sits, as fractions of the parent's preview width. |
| `scale` | number | The sticker's size relative to the parent's preview width. |
| `rotation` | number | In radians. |
| `parentPreviewWidth` | number | The width in points the client drew the parent balloon at. |
| `tapback` | boolean | Send it as a sticker tapback instead; see the next section. |
| `remove` | boolean | With `tapback`, take this account's sticker tapback back. |

**Placement is optional and partial.** A client that knows where the user dropped the sticker
sends all five placement fields. A client that only wants "a sticker on this message" sends
none, and the sticker goes over the middle of the part, about a third as wide as it, upright.
A field sent on its own overrides only that value. `StickerPlacement` documents the
coordinate space and holds the defaults as `StickerPlacement.centered`.

A received sticker reports its placement in these same five fields, so a client can send a
placement it was given back unchanged. "Where a received sticker sits" below covers the read
side.

```bash
curl -X POST "http://localhost:1234/api/v2/message/sticker?password=…" \
  -F "attachment=@sticker.png;type=image/png" \
  --form-string "chatGuid=<chat guid>" \
  --form-string "selectedMessageGuid=<message guid>" \
  --form-string "xScalar=0.8" --form-string "yScalar=0.2" \
  --form-string "scale=0.3" --form-string "parentPreviewWidth=240"
```

The response is the sticker's own message row, the way `POST /api/v1/message/react` answers
with the tapback's row, not the target's. Insert it into the conversation the way the client
inserts any other message row it sends.

### React with a sticker

The same route with `tapback: true` sends the image as a sticker tapback: Messages snaps it to
the tapback position, and it replaces this account's previous tapback on that message instead
of stacking. The placement fields are ignored. Send `tapback: true` with `remove: true` to take
it back. **Sticker tapbacks need macOS 15 or later**, which is where the class Messages uses
for them first appears. `.claude/docs/api.md` § Sticker tapbacks has the detail.

### Add an image to the user's library

`POST /api/v2/sticker` is described in section 3. A client offering "save to my stickers" has
to word it as "add to recents": the response's `shelf` is always `recent`, and nothing this
server can call puts a sticker in the saved drawer. The `identifier` in the response is usable
straight away on every read route.

**A response without an `identifier` is still a success.** If the store took the sticker but
this server can't read the store back, the body carries `saved: true`, no `identifier`, and a
`metadata.reason` naming Full Disk Access. Tell the user it was added and refresh the list
once access is granted.

### Render stickers a client receives

A sticker arrives as an ordinary message, through the socket and through `/message/query`. It
takes one of three shapes, and a client tells them apart by two fields on the message and one
on its attachment:

| Field | Placed on a message part | Sticker tapback | Sent as its own message |
| --- | --- | --- | --- |
| `associatedMessageType` | `"sticker"` | `"2007"`, or `"3007"` for a removal | `null` |
| `associatedMessageGuid` | `p:<part>/<target guid>` | `p:<part>/<target guid>` | `null` |
| attachment `stickerPlacement` | present | absent | absent |

In every shape, the image is the message's attachment, flagged `isSticker: true`. It
downloads like any other attachment, from `GET /api/v1/attachment/:guid/download`. When that
route converts, a HEIC sticker with transparency becomes a PNG and an animated one a GIF,
never a JPEG, so the transparency and the animation survive. The header of
`AttachmentDelivery` has the rules.

Draw a sticker tapback where any other tapback is drawn: Messages positions it, and the
sender's device chose no placement. A sticker sent as its own message has no target, so it
has nothing to be placed on.

**Sticker tapbacks come through as digits, not names.** `associatedMessageType` is the
reference's string mapping, which names only the twelve classic tapbacks and `sticker`, so
`2007` and `3007` arrive as their own digits. A client that switches on the name has to add
these two cases, or it reads a sticker tapback as an unknown reaction.

### Where a received sticker sits

A placed sticker's attachment carries `stickerPlacement`, the position its sender chose. It is
the same five values `POST /api/v2/message/sticker` takes, under the same names:

```json
"attachments": [{
  "guid": "<attachment guid>",
  "isSticker": true,
  "stickerPlacement": {
    "xScalar": 0.1087, "yScalar": 1.4608, "scale": 0.48,
    "rotation": -0.157, "parentPreviewWidth": 217.59
  }
}]
```

| Field | Meaning | Key in `sticker_user_info` |
| --- | --- | --- |
| `xScalar`, `yScalar` | Where the sticker's centre sits, as fractions of the parent's preview width. | `sxs`, `sys` |
| `scale` | The sticker's size, relative to the parent's preview width. | `ssa` |
| `rotation` | In radians. | `sro` |
| `parentPreviewWidth` | The width in points the sender's device drew the parent balloon at. | `spw` |

The values come from the attachment row's `sticker_user_info`, so every placed sticker has
them, whoever sent it: this server, an iPhone or another Mac. `StoredStickerPlacement` is the
decoder, and its header records what it accepts.

`stickerPlacement` is on every attachment object that is not part of a notification payload:

- the socket's `new-message` and `updated-message` events;
- the reply to `POST /api/v2/message/sticker`, which is the sticker's own row;
- `/message/query` and the other message reads, when `with` includes `attachment`;
- the attachment routes, such as `GET /api/v1/attachment/:guid`.

It is never on an FCM push or a webhook delivery. Both carry the notification shape, which
leaves out every attachment field a notification cannot use.

**The key is absent, not null, when there is no placement.** That covers a sticker tapback, a
sticker sent as its own message, and the rare placed sticker whose row is missing one of the
five values. Draw that last case over the middle of its target part.

These rules keep a received sticker where its sender put it:

- **Scale to your own balloon width.** The values are relative to the sender's
  `parentPreviewWidth`, not to yours, so multiply by the width you draw the parent at.
- **Don't clamp.** On a `chat.db` measured on macOS 27.0.1, `xScalar` runs below 0 and above
  1, and `yScalar` above 1 is common on a short single-line message. A sticker can hang off any
  edge of its parent.
- **Expect plain JSON numbers.** Messages stores the geometry as decimal strings on most rows
  and as real numbers on a few, measured on the same database. This server decodes both, so
  the wire carries numbers either way.

#### Keys this server does not put on the wire

`sticker_user_info` holds more than the geometry. The other keys say which sticker it is and
how it was made, not where it goes, so the server doesn't serve them:

| Key | What it is |
| --- | --- |
| `sid` | The sticker's own identifier. |
| `pid` | The sticker pack identifier. |
| `suri` | The external URI, in the same form as the library's `ZEXTERNALURI`. |
| `sli` | The layout intent. |
| `spv` | The sticker position version. |
| `safi` | The initial frame index of an animated sticker. |
| `sbid` | The balloon bundle identifier used for attribution. |
| `stickerEffectType` | The sticker's effect type. |

`PRIVATE_API_SURFACE.md` § Stickers has the selectors that write them.
