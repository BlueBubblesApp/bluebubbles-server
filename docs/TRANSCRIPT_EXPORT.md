# Transcript export

Exporting one conversation as a file: from the app's Export page, or over
`POST /api/v2/transcript/export`. Everything here describes this server's own behaviour; the Node
reference has no counterpart to any of it.

---

## What an export is

One conversation, every message in a window you choose, written oldest first to a single
file. Three shapes:

| Format | What it is for | What it holds |
|---|---|---|
| `json` | Another program | Every field. Keys are `snake_case`; dates carry both epoch milliseconds and an ISO 8601 string in the export's zone |
| `txt` | Reading and searching | One line per message: `[2024-03-01 14:03:12] Alice Example: hello`, with a heading when the day changes |
| `html` | Reading in a browser, printing | A self-contained page with bubbles, no script and no remote resource |

JSON is the canonical form and the other two are renderings of the same model. The sentences
the readable formats use for anything that is not plain text (a reaction, a rename, an Apple
Pay balloon, "1 Photo") are transcribed from the BlueBubbles client's own rendering code, so a
transcript reads the way the conversation looked in the app. The transcriptions and where each
came from are in `Sources/BBTranscript/MessageDescription.swift`.

### Rows

Every row carries who sent it, when, and what it is (`kind`):

- `message`: words, attachments, or both. Edits carry their earlier versions (`edits`), an
  unsent message says so (`is_unsent`) and keeps no words, invisible ink is not revealed.
- `reaction`: a tapback or emoji reaction. Its own row, in chronological order, naming the
  message it is on (`target_guid`, `target_part`) and quoting it (`target_summary`). A consumer
  that wants reactions nested under their messages groups them by `target_guid` in one pass.
- `group_event`: somebody added or removed, a rename, a left conversation, a changed photo, a
  shared location, a kept audio message, a FaceTime call. The sentence is in `description`.
- `balloon`: an iMessage app or a rich link. The app's name, the layout's captions, the
  summary, and the payload URL for a consumer that understands the app; a rich link carries
  its title, summary, site and URL under `link`.

Reactions are rows rather than children because the export is **streamed**: the conversation
is read a page at a time and written as it is read, so a hundred-thousand-message chat costs one
page of rows plus the attachment being copied. Nesting would mean holding every message until
its reactions had been seen.

### Attachments

`attachments` chooses how far they travel:

| Mode | Each attachment becomes |
|---|---|
| `none` | A count in the message line: "1 Photo", "2 Videos & 1 Audio message" |
| `metadata` | Name, type and size from the row. Nothing is read off disk |
| `files` | The file itself, copied to `attachments/<guid>/<name>` beside the transcript, and the whole export is one ZIP |

With `files`, HEIC is copied as JPEG and CAF as M4A by default (`convert_attachments`), the way
the attachment routes serve them, so the HTML page shows its pictures in any browser; off, every
file is byte for byte what Messages stored. An attachment whose file is not on this Mac (purged
to iCloud) is reported (`is_missing`) rather than failing the export;
`download_purged_attachments` asks iCloud for each through the Private API first, which needs
the helper and is slow per file.

The ZIP is written by this server (`ZipArchiveWriter`): deflated for text, stored for media,
streamed from disk, with ZIP64 records only when a size or offset needs them, so an ordinary
export opens anywhere.

---

## Who is who

A transcript names people three ways, in order, and says which it used (`name_source`):

1. **`client`**: a name the caller supplied with the request (`participants`). The BlueBubbles
   client has the phone's address book; this server often has none.
2. **`contacts`**: this server's contact index matched the address, when the Contacts
   integration is on.
3. **`none`**: nothing named the address, and `display_name` is the formatted address.

The address is always present beside the name, on every participant and on every message's
`sender`, so a consumer can re-resolve names afterwards: a JSON export from a server with no
contacts can be hydrated by a client that has them. This Mac's own messages are labelled
`me_label` (`Me` unless you say otherwise), and `sender` is null on them.

A business handle (`urn:biz:…`) reads as "Business", which is what the client shows.

---

## The window

`after` and `before` are **inclusive**, like the same parameters on `/message/query`, and
either may be absent. Over the API each accepts epoch milliseconds (a number, or a number in a
string) or an ISO 8601 date or date-time; a bare date (`2024-03-31`) is midnight at the start of
that day in this Mac's zone. The app's page takes whole days: "to 31 March" includes all of it.
`after` later than `before` is a 400.

Every readable date is in `time_zone` (an IANA identifier; this Mac's zone by default), and the
JSON `date_iso` strings carry the offset so they stay unambiguous.

---

## Finding the conversation

The API takes a chat GUID and nothing else identifies the conversation: a client has the GUID
in hand and its own contacts to show the person a name. There is deliberately no search route.

The app's Export page is where a person without a GUID finds a conversation, with the same
`ConversationPicker` the Scheduled page's composer uses, in single mode. It reads
`ConversationDirectory`, and the search matches, case-insensitively, the group's name, each
participant's contact name and address, and the GUID; a mostly-numeric query also matches the
digits of a phone number. The list is newest first, with arrow keys.

---

## Over the API

```
POST /api/v2/transcript/export
{
  "chat_guid": "iMessage;+;chat123456789",
  "format": "html",
  "after": "2024-01-01",
  "before": "2024-03-31T23:59:59Z",
  "attachments": "files",
  "participants": { "+15555550101": "Alice Example" },
  "me_label": "Me",
  "time_zone": "America/New_York"
}
```

The response is **the file**, not JSON about it: `Content-Type` follows the format
(`application/zip` when `attachments` is `files` or `archive` is true) and
`Content-Disposition` names it `<title>-<yyyyMMdd>-<yyyyMMdd>.<ext>`, so `curl -OJ` and a
browser both save it under a sensible name. The route's timeout is an hour, because copying
every attachment in a long conversation can take that long on a slow disk.

The file is written under `~/Library/Application Support/bluebubbles-server/exports/<uuid>/`
and streamed from there. The handler returns before the bytes are sent, so it cannot delete the
file afterwards; the next export's reservation removes anything older than an hour
(`TranscriptExportStore`), and nothing runs on an idle server.

Errors are the ordinary envelope: a 400 for a malformed body (the sentence names the field),
a 404 for a conversation this server does not have, a 503 when `chat.db` is not readable.

---

## In the app

Export, in the sidebar. Pick the conversation, choose the window, the format and what happens
to attachments, press Export and choose where it goes. The run lives on
`AppModel.transcriptExport` rather than on the page, so leaving the page while a long export
copies its attachments does not stop it; come back and the progress is still there, and Show in
Finder opens the result.

The page calls the same `TranscriptInterface` the API route calls, with the same options, so the
two cannot drift.

---

## Where the code is

| Piece | Where |
|---|---|
| The model, the sentences, the three writers, the ZIP writer | `Sources/BBTranscript/` |
| Filling the model from `chat.db` | `Sources/BBInterfaces/TranscriptInterface.swift` |
| Naming the chat and its people, and the list the picker shows | `Sources/BBInterfaces/ConversationDirectory.swift` |
| The route and its request body | `Sources/BBHandlers/TranscriptHandlers.swift`, `AdditiveRoutes.transcripts` |
| Where an API export waits to be downloaded | `Sources/BBMedia/TranscriptExportStore.swift` |
| The app page, its decisions, and the run it hands off | `Views/TranscriptExportView.swift`, `TranscriptExportOptions.swift`, `Models/TranscriptExportModel.swift`, and the shared `Views/Components/ConversationPicker.swift` |
| The decoders the export needed from `chat.db` | `AppMessagePayload.layout`, `RichLinkPayload`, `MessageEditHistory` in `Sources/BBIMessage/` |

Tests: `Tests/BBTranscriptTests` (every sentence, every format, the archive verified with
`unzip`), `Tests/BBInterfacesTests/TranscriptInterfaceTests.swift` (the export over a real
fixture database), `Tests/BBHandlersTests/TranscriptRequestShapeTests.swift` (the request body
against the OpenAPI declaration), `Tests/BlueBubblesAppTests/TranscriptExportOptionsTests.swift`
and `Tests/CompositionTests/TranscriptWiringTests.swift`.
