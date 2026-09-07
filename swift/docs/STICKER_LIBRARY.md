# The sticker library

How stickers are stored on a Mac, and how a client reads and adds them through this server.

This is about the sticker **library** — the picker's contents. Sending a sticker onto a
message is a different thing entirely and lives in `PRIVATE_API_SURFACE.md` § Stickers.

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
Disk Access — the same grant `chat.db` already requires — and nothing else.

### Two shelves

`ZMANAGEDSTICKER.ZTYPE` splits the store in two, and the API calls them shelves:

- **`saved`** (`ZTYPE = 1`) — the sticker drawer. What the user made and kept. Syncs via iCloud.
- **`recent`** (`ZTYPE = 0`) — recently used. Emoji and Memoji stickers *only* ever appear here.

The mapping was read off a live store rather than guessed. The giveaway is a sticker that is
on both shelves at once: this Mac holds one custom Live Sticker, and the store has two rows
for it —

```
Z_PK  ZTYPE  identifier    ZEXTERNALURI
5     1      AC20781C-…    sticker:///user/identifier/AC20781C-…
4     0      C229525C-…    sticker:///user/identifier/AC20781C-…
```

— a `ZTYPE = 1` row whose own identifier is `AC20781C-…`, and a `ZTYPE = 0` row with a fresh
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
than pattern-matching the URI itself — the emoji form ends in the literal emoji character,
which is easy to get wrong.

### Representations

A sticker has one or more renditions, and which ones depends on where it came from:

- A sticker **Messages made** has two — a full-size `com.apple.stickers.role.still` (usually
  HEIC, e.g. 900 × 712) and a small `com.apple.stickers.role.keyboard` PNG for the picker.
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

So `POST /api/v2/sticker` adds a **recent**. The response says `"shelf": "recent"`, and a
client should not promise the user anything else. The sticker is fully usable — it appears in
the picker and can be sent by identifier — it simply is not in the saved drawer.

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

Four routes, under `/api/v2/sticker`. All of them are mounted on every server — there is no
setting to turn v2 on.

### `GET /api/v2/sticker` — list the library

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

### `GET /api/v2/sticker/:id` — one sticker

The same object, on its own. `:id` accepts the dashed UUID the API reports; bare hex works
too. A malformed identifier is a 404, not a 500.

### `GET /api/v2/sticker/:id/image` — the bytes

Answers the image itself, with the representation's real `Content-Type` (`image/png`,
`image/heic`).

`?role=` picks the representation. `still` and `keyboard` are shorthands for the long
reverse-DNS role strings, so a client need not hard-code them; the full role string off a
representation works as well. Omitted serves the preferred one.

**A role this sticker does not have falls back to preferred rather than 404ing.** "This
sticker has no keyboard thumbnail" is not "there is no such sticker", and a client asking for
a thumbnail wants an image either way.

### `POST /api/v2/sticker` — add one

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

Answers with the sticker as the store now holds it — read back, not echoed — so the
`identifier` is immediately usable and the representation carries the UTI and size the store
derived from the bytes.

Note that `name` here means the **sticker's** name. On every other file route `name` renames
the uploaded file, because there it means "what the recipient sees"; on this one the file
keeps its own filename.

---

## 4. Notes for client authors

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
  array and a `metadata.reason` saying which — so a client should render "no stickers" and
  surface the reason rather than treating it as a failure.
- **To send one of these**, hand the bytes to `POST /api/v2/message/sticker`. There is no
  send-by-identifier route: that path wants a file, and `:id/image` is where to get one.
