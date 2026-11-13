//  RequestBodies+Messages
//  The message routes' bodies: the query with its `where` allowlist, a text send, a reaction,
//  the multipart send, an edit, an unsend and a notification hydration.
//
//  Its own file so a client author reading how a message is sent or found opens these and
//  not every other write route. The declaration model, the rules and `byHandler` are in
//  `RequestBodies.swift`.

import BBHTTPAPI

extension RequestBodies {

  /// Merged into `byHandler`.
  static let messageBodies: [HandlerID: Body] = [
    // MARK: v1 routes that grew fields this server's fixtures predate

    // The route the whole `where` allowlist exists for, and the one whose fixture is least
    // like a real request: the recording sends `limit`, `offset`, `sort` and `with`, so the
    // document described a page of the newest messages and not one of the four jobs clients
    // actually use this for. `where` in particular cannot be discovered — it is eight
    // statements matched on shape, and anything else is a 400 — so a client author reading
    // only the inferred body would have had to find them in `MessageFilter`.
    .messageQuery: Body(
      summary:
        "Pages the message table. Every field is optional: an empty body answers with the "
        + "newest 100 messages across every conversation. `metadata` carries `total` (rows "
        + "matching every filter, not the size of the table), `count` (rows on this page), "
        + "`limit` and `offset`.",
      properties: [
        Property(
          "chatGuid", .string,
          "Scope the page to one conversation. A GUID that names no chat answers 200 with an "
            + "empty `data` and a message naming it, which is how a client tells \"no such "
            + "chat\" from \"no messages matching\"."),
        Property(
          "dateField", .string,
          "Which date `after` and `before` bracket: `created` (the default, when it was "
            + "sent), `delivered`, `read`, `updated` (delivered or read, the window "
            + "`GET /message/count/updated` counts), `edited` or `retracted` (unsent). A "
            + "row whose chosen date is unset is never inside the window. Ours: a client "
            + "that was offline asks for what was delivered, read, edited or unsent since "
            + "its last sync, which `created` cannot answer. Anything else is a 400."),
        Property(
          "with", .array(of: .string),
          "Relations to load. Matched as substrings, so `chat`, `chats` and "
            + "`chat.participants` all select the chat relation: `chat`, "
            + "`chat.participants`, `attachment`, `attachment.metadata`, `attributedBody`, "
            + "`messageSummaryInfo`, `payloadData`, `appPayload`. The sending handle is always "
            + "loaded and "
            + "needs no entry. Ask for `attributedBody` if you render text: an outgoing "
            + "message's `text` column is null on Ventura and newer and its words are in "
            + "there. `attachment.metadata` opens each file off disk, so it costs a probe "
            + "per attachment and is off unless asked for. `appPayload` adds, on an "
            + "iMessage-app balloon only, the decoded object `GET /api/v2/message/app/:guid` "
            + "answers, `session_id` and `url` included."),
        Property(
          "where",
          .array(
            of: .object(properties: [
              Property(
                "statement", .string,
                "One of the statements listed above. Matched on shape, so spacing and the "
                  + "placeholder's name are yours: `message.ROWID>:since` is the same "
                  + "filter as `message.ROWID > :startRowId`.", required: true),
              Property(
                "args", .anything,
                "The bound values, keyed by placeholder name without its colon. An empty "
                  + "object for a statement that binds nothing.", required: true),
            ])),
          "Filters, ANDed together, and applied to `metadata.total` as well as to the page. "
            + "Each entry is one statement from a fixed set; a statement outside it is "
            + "refused with a 400 quoting it back, never ignored. The set: "
            + "`message.ROWID > :x`, `message.ROWID <= :x`, "
            + "`message.is_from_me = :x` (0 or 1), "
            + "`message.text LIKE :x COLLATE NOCASE` (write your own `%` wildcards), "
            + "`message.guid IN (:...x)`, `message.associated_message_guid IS NULL`, "
            + "`chat.guid = :x`, `handle.id = :x`."),
        Property(
          "limit", .integer, "Page size, 1 to 1000 inclusive. Defaults to 100."),
        Property("offset", .integer, "Rows to skip before the page. Defaults to 0."),
        Property(
          "sort", .string,
          "`DESC` for newest first, which is the default, or `ASC` for oldest first. Page a "
            + "sync with `ASC` so a message arriving mid-sync cannot shift a page you have "
            + "already read."),
        Property(
          "after", .integer,
          "Only messages sent at or after this time, epoch MILLISECONDS. Inclusive."),
        Property(
          "before", .integer,
          "Only messages sent at or before this time, epoch MILLISECONDS. Inclusive."),
        Property(
          "convertAttachments", .boolean,
          "Accepted and carried, but no field of this response depends on it: an attachment "
            + "is converted when it is downloaded, not when a message is serialized. "
            + "Defaults to true."),
      ],
      examples: [
        Example(
          "recent-in-chat",
          "The newest page of one conversation.",
          "The relations a transcript needs, in one request. `attributedBody` is in the list "
            + "because an outgoing message's `text` column is null on Ventura and newer.",
          .obj([
            ("chatGuid", .string("iMessage;-;+15551234567")),
            (
              "with",
              .array([
                .string("chat"), .string("chat.participants"), .string("attachment"),
                .string("attributedBody"), .string("messageSummaryInfo"),
              ])
            ),
            ("limit", .int(25)),
            ("sort", .string("DESC")),
          ])),
        Example(
          "incremental-sync",
          "One page of a fixed ROWID window.",
          "How a client catches up without re-reading what it already has. The top of the "
            + "window is pinned with `<=` so messages arriving mid-sync cannot shift the "
            + "pages under it; page until `metadata.count` is zero.",
          .obj([
            (
              "where",
              .array([
                .obj([
                  ("statement", .string("message.ROWID > :startRowId")),
                  ("args", .obj([("startRowId", .int(418_002))])),
                ]),
                // The top of the window is PINNED, so messages arriving mid-sync cannot
                // shift the pages under a client that is still reading them.
                .obj([
                  ("statement", .string("message.ROWID <= :endRowId")),
                  ("args", .obj([("endRowId", .int(420_679))])),
                ]),
              ])
            ),
            ("with", .array([.string("chat"), .string("attachment")])),
            ("sort", .string("ASC")),
            ("limit", .int(1000)),
            ("offset", .int(0)),
          ])),
        Example(
          "search-one-chat",
          "A text search inside one conversation.",
          "Reactions and replies are excluded by `associated_message_guid IS NULL`, which is "
            + "what keeps a search result list from filling with tapbacks.",
          .obj([
            (
              "where",
              .array([
                .obj([
                  ("statement", .string("message.text LIKE :term COLLATE NOCASE")),
                  ("args", .obj([("term", .string("%dinner%"))])),
                ]),
                .obj([
                  ("statement", .string("message.associated_message_guid IS NULL")),
                  ("args", .obj([])),
                ]),
                .obj([
                  ("statement", .string("chat.guid = :guid")),
                  ("args", .obj([("guid", .string("iMessage;-;+15551234567"))])),
                ]),
              ])
            ),
            ("with", .array([.string("chat"), .string("attributedBody")])),
            ("limit", .int(50)),
          ])),
        Example(
          "sent-by-me-to-one-handle",
          "This account's messages to one handle.",
          "Scoped to a time window as well. `after` and `before` are epoch milliseconds and "
            + "both bounds are inclusive.",
          .obj([
            (
              "where",
              .array([
                .obj([
                  ("statement", .string("message.is_from_me = :fromMe")),
                  ("args", .obj([("fromMe", .int(1))])),
                ]),
                .obj([
                  ("statement", .string("handle.id = :address")),
                  ("args", .obj([("address", .string("+15551234567"))])),
                ]),
              ])
            ),
            ("after", .int(1_788_400_000_000)),
            ("before", .int(1_788_486_400_000)),
            ("sort", .string("ASC")),
          ])),
        Example(
          "hydrate-by-guid",
          "The messages behind a set of GUIDs.",
          "How a client fills in a push notification: the payload carries GUIDs, and this "
            + "turns them into rows without a second request per message.",
          .obj([
            (
              "where",
              .array([
                .obj([
                  ("statement", .string("message.guid IN (:...guids)")),
                  (
                    "args",
                    .obj([
                      (
                        "guids",
                        .array([
                          .string("4D50CFE4-87A5-49D6-9687-4A5D6C94A29B"),
                          .string("B1F0A7C2-5E3D-4A19-9C48-7D2E6B0F3A51"),
                        ])
                      )
                    ])
                  ),
                ])
              ])
            ),
            ("with", .array([.string("chat"), .string("attachment")])),
          ])),
      ],
      required: false),

    .messageSendText: Body(
      summary: "Sends a text message.",
      properties: [
        chatGUID(),
        Property("message", .string, "The text to send.", required: true),
        // Neither is required unconditionally, which is all `required` can say: the
        // validator demands `tempGuid` only for an AppleScript send. See `ValidationRules`.
        Property(
          "tempGuid", .string,
          "Client-generated id echoed back on the sent message, so a client can match the "
            + "response to the row it inserted optimistically. Required for AppleScript."),
        Property(
          "method", .string,
          "`apple-script` or `private-api`. AppleScript needs no helper; the Private API is "
            + "required for subjects, effects, replies and formatting."),
        Property("subject", .string, "Subject line. Private API only."),
        Property(
          "effectId", .string,
          "A send effect, e.g. `com.apple.MobileSMS.expressivesend.impact`. Private API only."),
        Property(
          "selectedMessageGuid", .string,
          "The message this one replies to, threading it. Private API only."),
        Property("partIndex", .integer, "Which part of the replied-to message. Defaults to 0."),
        Property("ddScan", .boolean, "Scan the text for links and data detectors."),
        textFormatting,
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("tempGuid", .string("6E2C1A2B-0F2E-4E77-9B6C-2E5A3D9F1A44")),
        ("message", .string("bold and shaking")),
        ("method", .string("private-api")),
        (
          "textFormatting",
          .array([
            .obj([
              ("start", .int(0)), ("length", .int(4)), ("styles", .array([.string("bold")])),
            ]),
            .obj([("start", .int(9)), ("length", .int(8)), ("effect", .string("shake"))]),
          ])
        ),
      ])),

    .messageReact: Body(
      summary: "Sends a tapback, including an emoji one.",
      properties: [
        chatGUID("The conversation the target message is in."),
        Property(
          "selectedMessageGuid", .string, "The message being reacted to.", required: true),
        Property(
          "reaction", .string,
          "`love`, `like`, `dislike`, `laugh`, `emphasize`, `question` or `emoji`, each with "
            + "a `-` prefix to remove it (`-love`, `-emoji`).", required: true),
        Property(
          "emoji", .string,
          "The emoji, required for `emoji` and `-emoji` and ignored otherwise. macOS 15 and "
            + "newer."),
        Property("partIndex", .integer, "Which part of the target message. Defaults to 0."),
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("selectedMessageGuid", .string("4D50CFE4-87A5-49D6-9687-4A5D6C94A29B")),
        ("reaction", .string("emoji")),
        ("emoji", .string("🔥")),
      ])),

    // MARK: Message writes
    //
    // `parts` on the multipart route is the field with no discoverable shape: mentions,
    // inline attachments and per-run formatting all arrive through it, in order.

    .messageSendMultipart: Body(
      summary:
        "Sends one message assembled from ORDERED parts: text runs, mentions and attachments "
        + "in a single balloon. Private API only. The parts are applied in the order they "
        + "arrive, and a part carrying neither `text` nor `filePath` is refused rather than "
        + "skipped, because dropping one would renumber every part after it.",
      properties: [
        chatGUID(),
        Property(
          "parts",
          .array(
            of: .object(properties: [
              Property(
                "text", .string,
                "This part's text. A part needs `text` or `filePath`."),
              Property(
                "mention", .string,
                "The address this run mentions, which is what turns it into a mention rather "
                  + "than into text that looks like one. `text` is the name the recipient "
                  + "sees; this is who it resolves to."),
              Property(
                "filePath", .string,
                "A file already on this Mac, staged by `POST attachment/upload`, to send as "
                  + "this part: the `<uuid>/<file>` path that route answered with. "
                  + "`attachment` (the v1 name) and `attachmentPath` are accepted as well. "
                  + "Paths are confined to the upload store, so an arbitrary path on the Mac "
                  + "is refused."),
              Property(
                "name", .string,
                "The filename the recipient sees for this part's file. Outranks the name it "
                  + "was uploaded under; without it, that name is kept."),
              textFormatting,
              Property(
                "partIndex", .integer,
                "Sent by the app and not read: position in the array is the index. "
                  + "Documented because clients send it, not because it does anything."),
            ])),
          "The message, in order. One entry per run of text, mention or attachment.",
          required: true),
        Property(
          "tempGuid", .string,
          "Client-generated id echoed back on the sent message. Also the deduplication key: "
            + "a second send under a `tempGuid` still in flight is refused rather than sent "
            + "twice."),
        Property("subject", .string, "Subject line."),
        Property("effectId", .string, "A send effect, applied to the whole message."),
        Property(
          "selectedMessageGuid", .string, "The message this one replies to, threading it."),
        Property("partIndex", .integer, "Which part of the replied-to message. Defaults to 0."),
        Property(
          "ddScan", .boolean,
          "Scan the text for links and data detectors. The app sends it only to a server "
            + "older than macOS 14, and only when the text contains a URL."),
      ],
      examples: [
        Example(
          "mention-in-a-group",
          "A message that mentions someone.",
          "Three runs, and only the middle one carries `mention`. The mention is a property "
            + "of the run, so the name a recipient reads and the address it resolves to are "
            + "set in the same place.",
          .obj([
            ("chatGuid", .string("iMessage;+;chat000000000000000001")),
            ("tempGuid", .string("6E2C1A2B-0F2E-4E77-9B6C-2E5A3D9F1A44")),
            (
              "parts",
              .array([
                .obj([("text", .string("Morning "))]),
                .obj([
                  ("text", .string("Sam")), ("mention", .string("+15551234567")),
                ]),
                .obj([("text", .string(", are we still on for 7?"))]),
              ])
            ),
          ])),
        Example(
          "text-and-a-photo",
          "Text and an attachment in one balloon.",
          "The file is staged first with `POST attachment/upload`, whose response carries "
            + "the path to put here. Sending it as a part is what keeps it in the same "
            + "balloon as the text instead of arriving as a second message.",
          .obj([
            ("chatGuid", .string("iMessage;-;+15551234567")),
            ("tempGuid", .string("B1F0A7C2-5E3D-4A19-9C48-7D2E6B0F3A51")),
            (
              "parts",
              .array([
                .obj([("text", .string("Here it is"))]),
                .obj([
                  ("filePath", .string("8c7d9e0f-1a2b-3c4d-5e6f-708192a3b4c5/IMG_0001.heic")),
                  ("name", .string("Beach.heic")),
                ]),
              ])
            ),
          ])),
        Example(
          "formatted-reply",
          "A styled reply in a thread.",
          "`selectedMessageGuid` threads the message; `textFormatting` styles a range of one "
            + "part, in UTF-16 code units, so an emoji earlier in the run shifts the offsets.",
          .obj([
            ("chatGuid", .string("iMessage;-;+15551234567")),
            ("tempGuid", .string("4D50CFE4-87A5-49D6-9687-4A5D6C94A29B")),
            ("selectedMessageGuid", .string("F2A7C1D0-93B4-4E6A-8C15-0D7E2B9A4F38")),
            ("partIndex", .int(0)),
            (
              "parts",
              .array([
                .obj([
                  ("text", .string("Booked it")),
                  (
                    "textFormatting",
                    .array([
                      .obj([
                        ("start", .int(0)), ("length", .int(6)),
                        ("styles", .array([.string("bold")])),
                      ])
                    ])
                  ),
                ])
              ])
            ),
          ])),
      ]),

    .messageEdit: Body(
      summary:
        "Rewrites a message this account sent. Private API only, and the message must be "
        + "recent enough that Messages still allows an edit. The path's `:guid` is the "
        + "message; the body is what it becomes.",
      properties: [
        Property("editedMessage", .string, "The replacement text.", required: true),
        Property(
          "backwardsCompatibilityMessage", .string,
          "What a recipient on an OS that cannot render an edit receives in place of it. "
            + "Required, because the reference's validator requires it — and worth writing "
            + "deliberately: this is the sentence half the recipients actually see.",
          required: true),
        Property(
          "partIndex", .integer,
          "Which part of the message to rewrite. Defaults to 0, which is the whole of an "
            + "ordinary text message."),
      ],
      example: .obj([
        ("editedMessage", .string("Dinner at 8, not 7")),
        ("backwardsCompatibilityMessage", .string("Edited to \u{201C}Dinner at 8, not 7\u{201D}")),
        ("partIndex", .int(0)),
      ])),

    .messageUnsend: Body(
      summary:
        "Unsends a message this account sent, which removes it from every device in the "
        + "conversation. Private API only, and subject to the same recency limit Messages "
        + "applies to its own Undo Send.",
      properties: [
        Property(
          "partIndex", .integer,
          "Which part to retract. Defaults to 0, which is the whole of an ordinary text "
            + "message; a multipart message retracts one part at a time.")
      ],
      example: .obj([("partIndex", .int(0))]),
      required: false),

    // MARK: Notification hydration

    .messageHydrate: Body(
      summary:
        "Turns the message GUIDs a push notification carries into the message rows "
        + "themselves, in one request rather than one per message. A GUID that no longer "
        + "resolves is omitted rather than failing the batch, so `metadata.requested` and "
        + "`metadata.returned` are worth comparing.",
      properties: [
        Property(
          "guids", .array(of: .string),
          "The messages to fetch, at most 100. Deduplicated in order, so a burst of "
            + "notifications for the same message costs one lookup. An empty list is a 400.",
          required: true),
        Property(
          "withAttachments", .boolean,
          "Load each message's attachments. Off by default, which keeps the response small "
            + "on the radio a notification just woke up."),
      ],
      example: .obj([
        (
          "guids",
          .array([
            .string("4D50CFE4-87A5-49D6-9687-4A5D6C94A29B"),
            .string("B1F0A7C2-5E3D-4A19-9C48-7D2E6B0F3A51"),
          ])
        ),
        ("withAttachments", .bool(true)),
      ])),

  ]
}
