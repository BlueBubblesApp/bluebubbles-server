//  TranscriptHandlers
//  Exporting a conversation as a file, and finding the conversation to export.
//
//  Two routes under `/api/v2/transcript`. `GET chat` is the picker: a caller that knows a
//  person's name but not a chat GUID asks here and gets candidates with names resolved.
//  `POST export` writes the transcript to this server's export folder and answers with the
//  file itself, streamed, under a `Content-Disposition` naming it, so `curl -OJ` and a
//  browser both save it as "Team-20240101-20240301.zip".
//
//  The body is this server's own (`snake_case`, per `docs/NAMING.md`) and is read in one
//  place, `exportRequest`, so the OpenAPI declaration in `RequestBodies` and the handler can
//  be checked against each other by `V2ParameterParityTests`. Dates are accepted as epoch
//  milliseconds, like every v1 `after`/`before`, OR as ISO 8601, because a person typing a
//  curl command knows "2024-01-01" and does not know 1704067200000.
//
//  See `docs/TRANSCRIPT_EXPORT.md`.

import BBHTTPAPI
import BBInterfaces
import BBMedia
import BBSerialization
import BBTranscript
import Foundation

public enum TranscriptHandlers {

  public static func register(
    into registry: inout HandlerRegistry,
    context: some InterfaceProviding & TranscriptExportStoring
  ) {

    /// Conversations matching `?query=`, newest first, with names from this server's
    /// contacts. An empty query lists the most recent ones.
    registry.register(.transcriptChats) { request in
      let interfaces = try await context.requireInterfaces()
      let query = request.queryParameters["query"] ?? ""
      let limit = min(max(request.integer("limit") ?? 50, 1), 500)
      let includeArchived =
        request.has("include_archived") ? request.truthy("include_archived") : true
      let candidates = try await interfaces.transcript.searchChats(
        matching: query, limit: limit, includeArchived: includeArchived)
      return .data(
        .array(candidates.map(Self.serialize)),
        metadata: .object(["count": .int(candidates.count), "limit": .int(limit)]))
    }

    /// The export. Answers with the file, not with JSON about it.
    registry.register(.transcriptExport) { request in
      let interfaces = try await context.requireInterfaces()
      let exportRequest = try Self.exportRequest(try request.values())
      let candidate = try await interfaces.transcript.chat(guid: exportRequest.chatGUID)
      let filename = TranscriptInterface.filename(for: candidate.chat, request: exportRequest)
      let folder = try context.transcriptExports.reserve()
      let result = try await interfaces.transcript.export(
        exportRequest, to: folder.appendingPathComponent(filename))
      return .file(
        path: result.url.path, filename: result.filename, contentType: result.contentType)
    }
  }

  // MARK: - The request

  /// Reads the export body. Every key here is also declared in `RequestBodies`.
  static func exportRequest(_ values: RequestValues) throws -> TranscriptInterface.ExportRequest {
    let chatGUID = try values.requireString("chat_guid")
    let format = try enumeration(
      values.string("format"), key: "format", default: TranscriptFormat.json)
    let attachments = try enumeration(
      values.string("attachments"), key: "attachments",
      default: Transcript.AttachmentMode.metadata)
    var timeZone = TimeZone.current
    if let identifier = values.string("time_zone"), !identifier.isEmpty {
      guard let zone = TimeZone(identifier: identifier) else {
        throw BadRequest("`time_zone` must be an IANA zone identifier, like `Europe/London`")
      }
      timeZone = zone
    }
    var names: [String: String] = [:]
    if let raw = values["participants"], !raw.isNull {
      guard case .object(let entries) = raw else {
        throw BadRequest("`participants` must be an object of address to name")
      }
      for (address, value) in entries {
        guard let name = value.stringValue else {
          throw BadRequest("`participants` values must be strings")
        }
        names[address] = name
      }
    }
    // Files are only ever served as one archive: a folder cannot travel over HTTP.
    let archive = (values.bool("archive") ?? false) || attachments == .files
    return TranscriptInterface.ExportRequest(
      chatGUID: chatGUID, format: format,
      after: try date(values["after"], key: "after"),
      before: try date(values["before"], key: "before"),
      attachmentMode: attachments, archive: archive, participantNames: names,
      meLabel: values.string("me_label") ?? Transcript.defaultMeLabel, timeZone: timeZone,
      convertAttachments: values.bool("convert_attachments") ?? true,
      downloadPurgedAttachments: values.bool("download_purged_attachments") ?? false)
  }

  /// A closed set of spellings, refused with the list when the value is not one of them.
  static func enumeration<Value: RawRepresentable & CaseIterable>(
    _ raw: String?, key: String, default fallback: Value
  ) throws -> Value where Value.RawValue == String {
    guard let raw, !raw.isEmpty else { return fallback }
    guard let value = Value(rawValue: raw.lowercased()) else {
      let allowed = Value.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")
      throw BadRequest("`\(key)` must be one of \(allowed)")
    }
    return value
  }

  /// Epoch milliseconds (a number, or a number in a string) or an ISO 8601 date.
  static func date(_ value: JSONValue?, key: String) throws -> Date? {
    guard let value, !value.isNull else { return nil }
    switch value {
    case .int(let milliseconds):
      return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    case .int64(let milliseconds):
      return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    case .double(let milliseconds):
      guard milliseconds.isFinite else { throw BadRequest("`\(key)` must be a finite number") }
      return Date(timeIntervalSince1970: milliseconds / 1000)
    case .string(let text):
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { return nil }
      if let milliseconds = Double(trimmed), milliseconds.isFinite {
        return Date(timeIntervalSince1970: milliseconds / 1000)
      }
      if let parsed = WireDate.parse(trimmed) ?? Self.dateOnly(trimmed) { return parsed }
      throw BadRequest("`\(key)` must be epoch milliseconds or an ISO 8601 date")
    default:
      throw BadRequest("`\(key)` must be epoch milliseconds or an ISO 8601 date")
    }
  }

  /// `2024-01-31`, read as midnight at the start of that day in this Mac's zone, which is
  /// what a person typing a date means by it.
  static func dateOnly(_ text: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: text)
  }

  // MARK: - The response

  /// One candidate, as `GET transcript/chat` lists it. `ResponseBodies` declares the same
  /// keys; `TranscriptResponseShapeTests` holds the two together.
  static func serialize(_ candidate: TranscriptInterface.ChatCandidate) -> JSONValue {
    let chat = candidate.chat
    return .object([
      "guid": .string(chat.guid),
      "title": .string(chat.title),
      "display_name": chat.displayName.map(JSONValue.string) ?? .null,
      "is_group": .bool(chat.isGroup),
      "is_archived": .bool(candidate.isArchived),
      "service": chat.service.map(JSONValue.string) ?? .null,
      "last_message_date": candidate.lastMessageDate.map { .int64(Self.milliseconds($0)) }
        ?? .null,
      "participants": .array(chat.participants.map(Self.serialize)),
    ])
  }

  static func serialize(_ participant: Transcript.Participant) -> JSONValue {
    .object([
      "address": .string(participant.address),
      "service": participant.service.map(JSONValue.string) ?? .null,
      "name": participant.name.map(JSONValue.string) ?? .null,
      "name_source": .string(participant.nameSource.rawValue),
      "display_name": .string(participant.displayName),
    ])
  }

  private static func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded(.towardZero))
  }
}
