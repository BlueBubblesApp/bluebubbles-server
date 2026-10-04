//  TranscriptInterface
//  Exporting a conversation as a file, streamed out a page at a time.
//
//  Built around one constraint: the conversation is read a page at a time and written as
//  it is read, so a chat of any length costs one page of rows plus whatever attachment is
//  being copied at that moment. Nothing here holds the conversation.
//
//  The rendering lives in `BBTranscript` and none of it is repeated here: this file decides
//  what a row IS (a reaction, a group event, a balloon, words) from the columns, fills the
//  model, and hands it to a writer. The sentence a reaction reads as is the writer's
//  business, which is what keeps the three formats saying the same thing.
//
//  Who is who comes from `ConversationDirectory`, the same list every picker in the app
//  reads: a name the caller supplied with the request first, then this server's contacts,
//  then the formatted address. Every participant carries its address either way, so a
//  consumer can re-resolve the names afterwards. See `docs/TRANSCRIPT_EXPORT.md`.

import BBCore
import BBIMessage
import BBMedia
import BBSerialization
import BBSystem
import BBTranscript
import Foundation
import Logging

public struct TranscriptInterface: Sendable {

  /// Everything an export can be asked for. The defaults are what the app's page starts
  /// with and what the API applies when a field is absent.
  public struct ExportRequest: Sendable, Equatable {
    public var chatGUID: String
    public var format: TranscriptFormat
    /// Inclusive on both ends, like `after` and `before` on `/message/query`.
    public var after: Date?
    public var before: Date?
    public var attachmentMode: Transcript.AttachmentMode
    /// Produce one ZIP rather than a file (or, with files, a folder).
    public var archive: Bool
    /// Names the caller knows for addresses, which win over this server's contacts.
    public var participantNames: [String: String]
    public var meLabel: String
    public var timeZone: TimeZone
    /// Copy HEIC as JPEG and CAF as M4A, the way the attachment routes serve them, so the
    /// HTML page opens its pictures in any browser. Off keeps the originals byte for byte.
    public var convertAttachments: Bool
    /// Ask iCloud for a purged attachment through the Private API before giving up on it.
    /// Slow per file, and needs the helper; off, a purged file is reported missing.
    public var downloadPurgedAttachments: Bool

    public init(
      chatGUID: String, format: TranscriptFormat = .json, after: Date? = nil,
      before: Date? = nil, attachmentMode: Transcript.AttachmentMode = .metadata,
      archive: Bool = false, participantNames: [String: String] = [:],
      meLabel: String = Transcript.defaultMeLabel, timeZone: TimeZone = .current,
      convertAttachments: Bool = true, downloadPurgedAttachments: Bool = false
    ) {
      self.chatGUID = chatGUID
      self.format = format
      self.after = after
      self.before = before
      self.attachmentMode = attachmentMode
      self.archive = archive
      self.participantNames = participantNames
      self.meLabel = meLabel
      self.timeZone = timeZone
      self.convertAttachments = convertAttachments
      self.downloadPurgedAttachments = downloadPurgedAttachments
    }

    /// Whether the product is a ZIP. Without one, `files` makes a folder.
    public var producesZip: Bool { archive }
  }

  /// What was produced and where.
  public struct ExportResult: Sendable, Equatable {
    /// The file (or folder) at the destination the caller named.
    public let url: URL
    /// The name a download should carry.
    public let filename: String
    public let contentType: String
    public let isZip: Bool
    public let chat: Transcript.Chat
    public let summary: Transcript.Summary
  }

  /// Called after each page is written, with the running totals, so a screen can show
  /// progress. Runs on the exporting task; keep it quick.
  public typealias Progress = @Sendable (Transcript.Summary) -> Void

  /// Rows per read. The interface clamps to 1000 anyway; stated here so the loop's
  /// termination test names the same number.
  static let pageSize = 1000

  /// How many message summaries are kept for quoting under a reaction. Reactions target
  /// recent messages almost always; a miss falls back to a point read by GUID.
  static let summaryCacheCapacity = 4096

  private let repository: MessageRepository
  private let serializer: MessageSerializer
  private let attachments: AttachmentInterface
  private let conversations: ConversationDirectory
  private let conversion: AttachmentConversion?
  private let generator: String
  private let logger: Logger

  /// - Parameters:
  ///   - conversations: the directory every picker reads, which is what names the chat and
  ///     its participants here too.
  ///   - conversion: the converter the attachment routes use, or nil to always copy
  ///     originals.
  public init(
    repository: MessageRepository,
    serializer: MessageSerializer,
    attachments: AttachmentInterface,
    conversations: ConversationDirectory,
    conversion: AttachmentConversion? = nil,
    generator: String = TranscriptInterface.defaultGenerator,
    logger: Logger = Logger(label: "bluebubbles.interface.transcript")
  ) {
    self.repository = repository
    self.serializer = serializer
    self.attachments = attachments
    self.conversations = conversations
    self.conversion = conversion
    self.generator = generator
    self.logger = logger
  }

  /// "BlueBubbles Server 1.2.3": the bundle's own version, or a development marker.
  public static var defaultGenerator: String {
    let version =
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
    return "BlueBubbles Server \(version)"
  }

  // MARK: - The conversation, in the transcript's own terms

  /// The directory's row as the transcript carries it. Same fields, the transcript's own
  /// types: `BBTranscript` is a leaf and cannot name the directory.
  public static func chat(from conversation: ConversationDirectory.Conversation)
    -> Transcript.Chat
  {
    Transcript.Chat(
      guid: conversation.guid, displayName: conversation.displayName,
      isGroup: conversation.isGroup, service: conversation.service,
      participants: conversation.participants.map(participant(from:)))
  }

  static func participant(from participant: ConversationDirectory.Participant)
    -> Transcript.Participant
  {
    Transcript.Participant(
      address: participant.address, service: participant.service, name: participant.name,
      nameSource: Transcript.NameSource(rawValue: participant.nameSource.rawValue) ?? .none)
  }

  // MARK: - Exporting

  /// Writes the transcript to `destination` and answers with what was written.
  ///
  /// `destination` is the FINAL path: the transcript file, the ZIP, or (files without an
  /// archive) a folder. Anything already there is replaced. Intermediate files for a ZIP
  /// are written beside it and removed once the archive is closed, so a failed export
  /// leaves nothing behind but the log line.
  public func export(
    _ request: ExportRequest, to destination: URL, progress: Progress? = nil
  ) async throws -> ExportResult {
    try Self.validate(request)
    let conversation = try await conversations.conversation(
      guid: request.chatGUID, names: request.participantNames)
    let chat = Self.chat(from: conversation)
    // Senders by address, grown as the pages are read: a sender who has since left the
    // group is not among the participants and is named on first sight, once.
    var people = Dictionary(
      uniqueKeysWithValues: chat.participants.map { ($0.address, $0) })
    let header = Transcript.Header(
      chat: chat, format: request.format, attachmentMode: request.attachmentMode,
      after: request.after, before: request.before, timeZone: request.timeZone,
      meLabel: request.meLabel, exportedAt: Date(), generator: generator)

    let layout = try Layout(request: request, destination: destination)
    defer { layout.cleanUp() }
    let output = try TranscriptOutput(url: layout.transcriptURL)
    let writer = request.format.makeWriter(output: output)
    try writer.begin(header)

    let messages = MessageInterface(repository: repository, serializer: serializer)
    var summary = Transcript.Summary()
    var summaries = BoundedCache<String, String>(capacity: Self.summaryCacheCapacity)
    var otherHandles: [Int64: HandleRow] = [:]
    var offset = 0
    var previousPage = Set<String>()
    while true {
      try Task.checkCancellation()
      let query = MessageInterface.Query(
        chatGUID: request.chatGUID, limit: Self.pageSize, offset: offset, ascending: true,
        after: request.after, before: request.before, withChats: false,
        withAttachments: true, withHandle: true,
        withAttachmentMetadata: request.attachmentMode == .files)
      let page = try await messages.query(query)
      let currentPage = Set(page.map(\.row.guid))
      for projection in page where !previousPage.contains(projection.row.guid) {
        let row = projection.row
        if !row.isFromMe, let handle = projection.relations.handle, people[handle.id] == nil {
          people[handle.id] = Self.participant(
            from: await conversations.participant(
              address: handle.id, service: handle.service, names: request.participantNames))
        }
        var message = try await transcriptMessage(
          projection, people: &people, request: request, summaries: &summaries,
          otherHandles: &otherHandles)
        if request.attachmentMode == .files {
          message.attachments = await copyAttachments(
            message.attachments, rows: projection.relations.attachments, into: layout,
            request: request)
        }
        try writer.write(message)
        summary.record(message)
        if let quote = TranscriptLine.summary(for: message, header: header) {
          summaries.insert(quote, for: message.guid)
        }
      }
      progress?(summary)
      if page.count < Self.pageSize { break }
      offset += page.count
      previousPage = currentPage
    }
    try writer.finish(summary)

    if request.producesZip {
      try layout.archive(transcriptName: Self.transcriptFilename(for: request.format))
    }
    let filename = Self.filename(for: chat, request: request)
    logger.info(
      "Transcript exported",
      metadata: [
        "format": .string(request.format.rawValue),
        "rowCount": .stringConvertible(summary.messageCount),
        "attachmentCount": .stringConvertible(summary.attachmentCount),
        "zip": .stringConvertible(request.producesZip),
      ])
    return ExportResult(
      url: destination, filename: filename,
      contentType: request.producesZip ? "application/zip" : request.format.contentType,
      isZip: request.producesZip, chat: chat, summary: summary)
  }

  static func validate(_ request: ExportRequest) throws {
    guard !request.chatGUID.isEmpty else {
      throw InterfaceError.invalidRequest("`chat_guid` is required")
    }
    if let after = request.after, let before = request.before, after > before {
      throw InterfaceError.invalidRequest("`after` must not be later than `before`")
    }
    guard !request.meLabel.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw InterfaceError.invalidRequest("`me_label` must not be empty")
    }
  }

  // MARK: Rows into the model

  /// Decides what the row is and fills the model from it.
  private func transcriptMessage(
    _ projection: MessageInterface.MessageProjection,
    people: inout [String: Transcript.Participant],
    request: ExportRequest,
    summaries: inout BoundedCache<String, String>,
    otherHandles: inout [Int64: HandleRow]
  ) async throws -> Transcript.Message {
    let row = projection.row
    let sender: Transcript.Participant? =
      row.isFromMe ? nil : projection.relations.handle.flatMap { people[$0.id] }
    let history = MessageEditHistory.decode(row.messageSummaryInfo)
    var message = Transcript.Message(
      guid: row.guid, date: row.date?.date, dateDelivered: row.dateDelivered?.date,
      dateRead: row.dateRead?.date, dateEdited: row.dateEdited?.date,
      dateRetracted: row.dateRetracted?.date, isFromMe: row.isFromMe, sender: sender,
      text: row.universalText(), subject: row.subject,
      attachments: projection.relations.attachments.map {
        Self.attachment($0, metadata: projection.relations.attachmentMetadata[$0.guid])
      },
      edits: history?.earlierVersions.map { Transcript.Edit(date: $0.date, text: $0.text) }
        ?? [],
      isUnsent: row.dateRetracted != nil || !(history?.retractedParts.isEmpty ?? true),
      replyToGUID: row.threadOriginatorGUID, effect: row.expressiveSendStyleID,
      service: row.service, isAudioMessage: row.isAudioMessage, error: row.error)

    if row.associatedMessageType != 0, let target = row.associatedMessageTarget {
      let quote = try await targetSummary(target.guid, summaries: &summaries)
      message.kind = .reaction(
        Transcript.Reaction(
          type: Self.reactionType(row.associatedMessageType),
          emoji: row.associatedMessageEmoji.flatMap { $0.isEmpty ? nil : $0 },
          targetGUID: target.guid, targetPart: target.partIndex, targetSummary: quote))
      // A reaction's own `text` is Messages' rendering ("Loved “hi”"), which the
      // description already says in the client's words.
      message.text = nil
      return message
    }
    if row.itemType != 0 || row.groupActionType != 0 || row.groupTitle != nil {
      var other: Transcript.Participant?
      if let otherID = row.otherHandle, otherID != 0 {
        if otherHandles[otherID] == nil,
          let handle = try await repository.handle(rowID: otherID)
        {
          otherHandles[otherID] = handle
        }
        if let handle = otherHandles[otherID] {
          if people[handle.id] == nil {
            people[handle.id] = Self.participant(
              from: await conversations.participant(
                address: handle.id, service: handle.service, names: request.participantNames))
          }
          other = people[handle.id]
        }
      }
      message.kind = .groupEvent(
        Transcript.GroupEvent(
          itemType: row.itemType, groupActionType: row.groupActionType,
          groupTitle: row.groupTitle, other: other))
      return message
    }
    if let bundleID = row.balloonBundleID, !bundleID.isEmpty {
      message.kind = .balloon(Self.balloon(bundleID: bundleID, row: row))
    }
    return message
  }

  /// The reference's spelling for a tapback type, extended with the two emoji types it
  /// predates: `emoji` (2006) and `-emoji` (3006). A sticker tapback (2007) reads as
  /// `sticker`.
  static func reactionType(_ raw: Int) -> String {
    switch raw {
    case 2006: return "emoji"
    case 3006: return "-emoji"
    case 2007: return "sticker"
    case 3007: return "-sticker"
    default: return ReactionWireType.name(for: raw) ?? String(raw)
    }
  }

  /// What the reaction was on, quoted from the cache or read by GUID.
  private func targetSummary(
    _ guid: String, summaries: inout BoundedCache<String, String>
  ) async throws -> String? {
    if let cached = summaries[guid] { return cached }
    guard let target = try await repository.message(guid: guid) else { return nil }
    var quote = target.universalText()
    if quote == nil, target.cacheHasAttachments {
      let rows = try await repository.attachments(forMessageGUID: guid)
      let described = AttachmentText.describe(rows.map { Self.attachment($0, metadata: nil) })
      quote = described.isEmpty ? nil : described
    }
    if quote == nil, let bundleID = target.balloonBundleID, !bundleID.isEmpty {
      quote = BalloonText.describe(Self.balloon(bundleID: bundleID, row: target))
    }
    if let quote { summaries.insert(quote, for: guid) }
    return quote
  }

  static func attachment(_ row: AttachmentRow, metadata: AttachmentMetadata?)
    -> Transcript.Attachment
  {
    Transcript.Attachment(
      guid: row.guid,
      name: row.transferName ?? row.resolvedPath.map { ($0 as NSString).lastPathComponent },
      mimeType: row.mimeType, byteSize: row.totalBytes, width: metadata?.width,
      height: metadata?.height, isSticker: row.isSticker)
  }

  static func balloon(bundleID: String, row: IMessageRow) -> Transcript.Balloon {
    if BalloonCatalog.isRichLink(bundleID) {
      let link = RichLinkPayload.decode(row.payloadData)
      return Transcript.Balloon(
        bundleID: bundleID,
        url: link?.url ?? link?.originalURL ?? row.universalText(),
        link: Transcript.Link(
          url: link?.url ?? link?.originalURL ?? row.universalText(), title: link?.title,
          summary: link?.summary, siteName: link?.siteName))
    }
    let envelope = AppMessagePayload.envelope(from: row.payloadData)
    let layout = AppMessagePayload.layout(from: row.payloadData)
    return Transcript.Balloon(
      bundleID: bundleID, appName: envelope?.appName,
      caption: layout?.caption ?? envelope?.caption, subcaption: layout?.subcaption,
      secondarySubcaption: layout?.secondarySubcaption, imageTitle: layout?.imageTitle,
      imageSubtitle: layout?.imageSubtitle, summary: envelope?.summary, url: envelope?.url)
  }

  // MARK: Files

  /// Copies each attachment into the export and records where it went, or that it could
  /// not be found. A file that fails to copy is reported missing rather than failing the
  /// export: one unreadable photo should not cost a year of messages.
  private func copyAttachments(
    _ attachments: [Transcript.Attachment], rows: [AttachmentRow], into layout: Layout,
    request: ExportRequest
  ) async -> [Transcript.Attachment] {
    var copied = attachments
    for (index, row) in rows.enumerated() where index < copied.count {
      do {
        guard var source = try await sourcePath(for: row, request: request) else {
          copied[index].isMissing = true
          continue
        }
        var mimeType = row.mimeType ?? ""
        if request.convertAttachments, let conversion, !mimeType.isEmpty {
          let resolved = await conversion.resolve(
            path: source, mimeType: mimeType, options: AttachmentConversion.Options())
          source = resolved.path
          mimeType = resolved.mimeType
        }
        let name = Self.exportedName(
          for: row, sourcePath: source, convertedFrom: row.mimeType, to: mimeType)
        let relative = "attachments/\(row.guid)/\(name)"
        let target = layout.contentRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
          try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: target)
        copied[index].exportedPath = relative
        copied[index].mimeType = mimeType.isEmpty ? row.mimeType : mimeType
        copied[index].name = name
      } catch {
        copied[index].isMissing = true
        logger.debug(
          "An attachment could not be copied into the export",
          metadata: [
            "attachmentGuid": .string(row.guid),
            "reason": .string(String(describing: error)),
          ])
      }
    }
    return copied
  }

  /// Where the bytes are, or nil when they are not on this Mac.
  private func sourcePath(for row: AttachmentRow, request: ExportRequest) async throws
    -> String?
  {
    if let path = row.resolvedPath, FileManager.default.fileExists(atPath: path) {
      return path
    }
    guard request.downloadPurgedAttachments else { return nil }
    // Asks iCloud through the helper; `AttachmentInterface` reports the two ways that can
    // fail and both are "missing" here.
    return try await attachments.resolvePath(guid: row.guid)
  }

  /// A safe file name for the copy: the transfer name, with the extension the converted
  /// bytes actually have, and nothing a path could misread.
  static func exportedName(
    for row: AttachmentRow, sourcePath: String, convertedFrom original: String?,
    to mimeType: String
  ) -> String {
    var base = row.transferName ?? (sourcePath as NSString).lastPathComponent
    base = sanitise(base)
    if base.isEmpty { base = row.guid }
    let sourceExtension = (sourcePath as NSString).pathExtension
    if let original, original != mimeType, !sourceExtension.isEmpty {
      base = ((base as NSString).deletingPathExtension as NSString)
        .appendingPathExtension(sourceExtension) ?? base
    }
    return base
  }

  /// Strips what a file system or a ZIP reader would choke on.
  static func sanitise(_ name: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/\\:\u{0}").union(.controlCharacters)
    var cleaned = name.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) }
    while cleaned.first == "." { cleaned.removeFirst() }
    let joined = String(cleaned).trimmingCharacters(in: .whitespaces)
    return String(joined.prefix(180))
  }

  // MARK: Naming

  static func transcriptFilename(for format: TranscriptFormat) -> String {
    "transcript.\(format.fileExtension)"
  }

  /// `Team-20240101-20240301.zip`: the title, the window, the shape.
  static func filename(for chat: Transcript.Chat, request: ExportRequest) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = request.timeZone
    formatter.dateFormat = "yyyyMMdd"
    var pieces = [slug(chat.title)]
    if request.after != nil || request.before != nil {
      pieces.append(request.after.map(formatter.string(from:)) ?? "start")
      pieces.append(request.before.map(formatter.string(from:)) ?? "end")
    }
    let stem = pieces.joined(separator: "-")
    if request.producesZip { return "\(stem).zip" }
    return request.attachmentMode == .files
      ? stem : "\(stem).\(request.format.fileExtension)"
  }

  /// Letters, digits and a dash, from whatever the conversation is called.
  static func slug(_ title: String) -> String {
    var out = ""
    var lastWasDash = false
    for scalar in title.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        out.unicodeScalars.append(scalar)
        lastWasDash = false
      } else if !lastWasDash, !out.isEmpty {
        out.append("-")
        lastWasDash = true
      }
    }
    while out.hasSuffix("-") { out.removeLast() }
    let trimmed = String(out.prefix(60))
    return trimmed.isEmpty ? "transcript" : trimmed
  }

  // MARK: Where the files go

  /// The paths for one export, and the clean-up that follows it.
  struct Layout {
    /// Where the transcript file and `attachments/` are written.
    let contentRoot: URL
    let transcriptURL: URL
    /// The ZIP to produce, when one is asked for.
    let zipURL: URL?
    /// A scratch folder to delete afterwards, when the product is a ZIP.
    let scratch: URL?

    init(request: ExportRequest, destination: URL) throws {
      let manager = FileManager.default
      if request.producesZip {
        let scratch = destination.deletingLastPathComponent()
          .appendingPathComponent(".bb-export-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(
          at: scratch, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        contentRoot = scratch
        transcriptURL = scratch.appendingPathComponent(
          TranscriptInterface.transcriptFilename(for: request.format))
        zipURL = destination
        self.scratch = scratch
      } else if request.attachmentMode == .files {
        // A folder: the transcript beside its attachments.
        if manager.fileExists(atPath: destination.path) {
          try manager.removeItem(at: destination)
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        contentRoot = destination
        transcriptURL = destination.appendingPathComponent(
          TranscriptInterface.transcriptFilename(for: request.format))
        zipURL = nil
        scratch = nil
      } else {
        contentRoot = destination.deletingLastPathComponent()
        transcriptURL = destination
        zipURL = nil
        scratch = nil
      }
    }

    /// Zips the transcript and every file under `attachments/` into `zipURL`.
    func archive(transcriptName: String) throws {
      guard let zipURL else { return }
      let zip = try ZipArchiveWriter(url: zipURL)
      try zip.add(fileAt: transcriptURL, as: transcriptName)
      let attachmentsRoot = contentRoot.appendingPathComponent("attachments", isDirectory: true)
      // Relative paths, which is what the entry names are; `enumerator(atPath:)` yields
      // them directly and sorted, so two exports of one conversation zip identically.
      if let enumerator = FileManager.default.enumerator(atPath: attachmentsRoot.path) {
        for case let relative as String in enumerator {
          let kind = enumerator.fileAttributes?[.type] as? FileAttributeType
          guard kind == .typeRegular else { continue }
          let file = attachmentsRoot.appendingPathComponent(relative)
          try zip.add(
            fileAt: file, as: "attachments/\(relative)",
            method: .suggested(forMIMEType: FileTypes.mimeType(for: file.path)))
        }
      }
      try zip.finish()
    }

    func cleanUp() {
      guard let scratch else { return }
      try? FileManager.default.removeItem(at: scratch)
    }
  }
}
