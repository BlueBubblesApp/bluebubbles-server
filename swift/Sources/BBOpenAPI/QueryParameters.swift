//  QueryParameters
//  The query string, per handler.
//
//  HAND-WRITTEN, and it has to be. Handlers read `request.queryParameters` by string, so
//  there is no type to reflect on and nothing in the route table records them — which is why
//  the document described `?pretty` and nothing else, while `GET /message/query` quietly took
//  six. A client author reading the generated page had no way to learn pagination existed.
//
//  Inference could not fill this in either. The recorder hashes query KEYS into a fixture's
//  filename and does not store them per operation, so a corpus proves a parameter was used
//  once, not what it means or what it accepts.
//
//  ASSEMBLED FROM THREE SOURCES, deliberately:
//    1. The handlers, for which parameters are actually read — authoritative for existence.
//    2. The Flutter client (`bluebubbles-app/lib/services/network/api/*.dart`), for which
//       ones real clients send and what they send in them.
//    3. The reference server, for the semantics the v1 surface is frozen against.
//
//  Keyed by `HandlerID` rather than operation, because four route entries share two
//  participant handlers and both spellings take the same query.
//
//  See docs/api/README.md § Query parameters.

import BBHTTPAPI

public enum QueryParameters {

  public struct Parameter: Sendable {
    public let name: String
    public let type: String
    public let description: String
    /// Present for a parameter whose accepted values are a closed set.
    public let allowed: [String]?
    /// What the server uses when the parameter is absent.
    public let defaultValue: String?

    init(
      _ name: String, _ type: String, _ description: String,
      allowed: [String]? = nil, defaultValue: String? = nil
    ) {
      self.name = name
      self.type = type
      self.description = description
      self.allowed = allowed
      self.defaultValue = defaultValue
    }
  }

  // MARK: - Shared shapes

  /// `?with=` — the relation loader.
  ///
  /// Matched as a SUBSTRING against a comma-separated list, not by equality: clients spell
  /// the same relation several ways (`chat`, `chats`, `chat.participants`) and the reference
  /// server accepts all of them, so the port does too.
  static func with(_ options: String) -> Parameter {
    Parameter(
      "with", "string",
      "Comma-separated relations to include. Matched as substrings, so `chat`, `chats` and "
        + "`chat.participants` all select the chat relation. Options: \(options)."
    )
  }

  static let limit = Parameter(
    "limit", "integer", "Maximum rows to return.", defaultValue: "100")
  static let offset = Parameter(
    "offset", "integer", "Rows to skip, for paging.", defaultValue: "0")
  static let sort = Parameter(
    "sort", "string", "Sort direction by date.",
    allowed: ["ASC", "DESC"], defaultValue: "DESC")
  static let after = Parameter(
    "after", "integer", "Only rows after this instant, in epoch MILLISECONDS.")
  static let before = Parameter(
    "before", "integer", "Only rows before this instant, in epoch MILLISECONDS.")

  // MARK: - The table

  public static let byHandler: [HandlerID: [Parameter]] = [
    // Reads
    .chatMessages: [
      with("`handle`, `chat`/`chats`, `attachment`/`attachments`, `attributedBody`"),
      sort, after, before, offset, limit,
    ],
    .chatFind: [with("`participants`, `lastmessage`")],
    .stickerList: [
      Parameter(
        "source", "string",
        "Which shelf of the library to list. `all` is both, and is the default because a "
          + "client showing the user their stickers wants the whole picker. A "
          + "comma-separated pair (`saved,recent`) means the same as `all`. Every row says "
          + "which shelf it came from either way.",
        allowed: ["all", "saved", "recent"], defaultValue: "all"),
      limit, offset,
    ],
    .stickerImage: [
      Parameter(
        "role", "string",
        "Which rendition to serve. `still` is the full-size image and `keyboard` the "
          + "picker thumbnail; the store's own reverse-DNS role string is accepted too. "
          + "Omitted serves the preferred rendition, which is the full-size one. A role "
          + "this sticker does not have falls back to preferred rather than 404ing.",
        allowed: ["still", "keyboard"])
    ],
    .chatCount: [
      Parameter(
        "includeArchived", "boolean",
        "Count archived conversations too. Truthy accepts `1`, `true`, `yes`, or a bare "
          + "`?includeArchived` with no value.", defaultValue: "false")
    ],
    .chatPinned: [with("`participants`, `lastmessage`")],
    .chatUpdate: [with("`participants`, `lastmessage`")],
    .messageFind: [with("`chat`/`chats`, `attachment`/`attachments`, `handle`")],
    .messageCount: [
      after, before,
      Parameter("chatGuid", "string", "Count only within this conversation."),
    ],
    .messageCountUpdated: [after, before],
    .messageSentCount: [after, before],
    .handleFind: [with("`chat`/`chats`")],
    .contactList: [
      limit, offset,
      Parameter(
        "extraProperties", "string",
        "Comma-separated extra fields to include. `avatar` is the one the Flutter client "
          + "asks for, and it is expensive — base64 image data per contact."),
    ],
    .handleIMessageAvailability: [
      Parameter("address", "string", "The phone number or email to check. REQUIRED.")
    ],
    .handleFaceTimeAvailability: [
      Parameter("address", "string", "The phone number or email to check. REQUIRED.")
    ],

    // Attachments
    .attachmentDownload: [
      Parameter(
        "original", "boolean",
        "Serve the file as stored rather than converting it. HEIC and CAF are converted by "
          + "default for clients that cannot read them.", defaultValue: "false"),
      Parameter("quality", "number", "JPEG quality when converting, 0–1."),
      Parameter("width", "integer", "Resize width in pixels, preserving aspect."),
      Parameter("height", "integer", "Resize height in pixels, preserving aspect."),
    ],
    .attachmentBlurhash: [
      Parameter("componentX", "integer", "Horizontal BlurHash components.", defaultValue: "3"),
      Parameter("componentY", "integer", "Vertical BlurHash components.", defaultValue: "3"),
    ],
    .chatFetchBackground: [
      Parameter(
        "wait", "number",
        "Seconds to wait for the download before returning. Absent returns as soon as the "
          + "fetch is requested.")
    ],

    // Server
    .serverLogs: [
      Parameter("count", "integer", "Lines to return from the tail.", defaultValue: "100")
    ],
    .serverAlerts: [limit],
    .serverAlertsV2: [limit],
    .serverStatMedia: [
      Parameter(
        "only", "string",
        "Comma-separated categories to count. Omit for all.",
        allowed: ["image", "video", "audio", "location", "link", "other"])
    ],
    .serverStatMediaByChat: [
      Parameter(
        "only", "string",
        "Comma-separated categories to count. Omit for all.",
        allowed: ["image", "video", "audio", "location", "link", "other"])
    ],
    .serverInstallUpdate: [
      Parameter(
        "wait", "boolean",
        "Block until the download finishes rather than returning as soon as it starts.",
        defaultValue: "false")
    ],

    // Scheduled messages
    .scheduleList: [
      Parameter(
        "status", "string", "Return only messages in this state.",
        allowed: ["pending", "sent", "error"])
    ],

    // Backups — name may arrive in the body OR the query, and both ship.
    .backupDeleteTheme: [
      Parameter("name", "string", "Theme to delete. May also be sent in the body.")
    ],
    .backupDeleteSettings: [
      Parameter("name", "string", "Settings backup to delete. May also be sent in the body.")
    ],
    .backupGetTheme: [Parameter("name", "string", "Fetch one theme instead of all.")],
    .backupGetSettings: [
      Parameter("name", "string", "Fetch one settings backup instead of all.")
    ],

    // Participants. Four route entries share these two handlers, and the address may arrive
    // in the body or the query on either spelling.
    .chatAddParticipant: [
      Parameter("address", "string", "Participant to add. May also be sent in the body.")
    ],
    .chatRemoveParticipant: [
      Parameter("address", "string", "Participant to remove. May also be sent in the body.")
    ],

    // FaceTime
    .facetimeRecents: [
      Parameter(
        "service", "string",
        "Which call log to read. Anything other than `all` returns FaceTime calls only.",
        allowed: ["facetime", "all"], defaultValue: "facetime")
    ],

    // Webhooks
    .webhookList: [
      Parameter("url", "string", "Return only the webhook with this URL."),
      Parameter("id", "integer", "Return only the webhook with this id."),
    ],
  ]
}
