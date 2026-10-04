//  Transcript
//  The export's own model of a conversation: what a transcript carries, independent of
//  where the rows came from and of the file it is written to.
//
//  A leaf module on purpose. The interface layer fills this model from `chat.db` and the
//  contact index; the writers in this module turn it into a file. Neither side knows the
//  other, which is what lets every rendering rule be tested from a handful of values rather
//  than from a fixture database, and lets the same model be rendered three ways without the
//  three renderers each re-deciding what a reaction or a group event means.
//
//  Two decisions shape the model. **A message carries its sender as a `Participant`, not as
//  a name**, so a consumer with its own address book (the BlueBubbles client has the phone's
//  contacts; this server often has none) can substitute names after the fact: `address` is
//  always present and `name` says where it came from. **A reaction is a row of its own**, in
//  chronological order, rather than nested under its target. The transcript is streamed one
//  message at a time so a hundred-thousand-message conversation never has to fit in memory,
//  and nesting would mean holding every message until its reactions had been seen. The
//  target is named on the reaction (`targetGUID`) so a consumer that wants them grouped can
//  do so in one pass.

import BBCore
import Foundation

/// The transcript as a whole: a header, a stream of messages, and a summary.
public enum Transcript {

  /// Where a participant's name came from, so a consumer can decide whether to trust it or
  /// replace it with a name of its own.
  public enum NameSource: String, Sendable, Equatable, Codable {
    /// This server's contact index matched the address.
    case contacts
    /// The caller supplied the name with the request.
    case client
    /// Nothing named this address; `displayName` is the formatted address.
    case none
  }

  /// Somebody in the conversation. The address is the identity; the name is a decoration.
  public struct Participant: Sendable, Equatable {
    /// The handle as `chat.db` stores it: an E.164 number or an email.
    public var address: String
    /// `iMessage`, `SMS` or `RCS`, when known.
    public var service: String?
    /// A contact or client-supplied name, when there is one.
    public var name: String?
    public var nameSource: NameSource

    public init(
      address: String, service: String? = nil, name: String? = nil, nameSource: NameSource = .none
    ) {
      self.address = address
      self.service = service
      self.name = name
      self.nameSource = nameSource
    }

    /// What a reader sees: the name when there is one, otherwise the address as a person
    /// would write it. A business handle (`urn:biz:…`) reads as "Business", which is how
    /// the client labels one (`handle.dart`, `displayName`).
    public var displayName: String {
      if let name, !name.isEmpty { return name }
      if address.hasPrefix("urn:biz") { return "Business" }
      return address.contains("@") ? address : AddressFormatting.phone(address)
    }
  }

  /// The conversation being exported.
  public struct Chat: Sendable, Equatable {
    public var guid: String
    /// The name the group was given, if any. Empty for a direct chat.
    public var displayName: String?
    public var isGroup: Bool
    public var service: String?
    /// Everyone in the conversation other than this Mac's own account.
    public var participants: [Participant]

    public init(
      guid: String, displayName: String? = nil, isGroup: Bool, service: String? = nil,
      participants: [Participant]
    ) {
      self.guid = guid
      self.displayName = displayName
      self.isGroup = isGroup
      self.service = service
      self.participants = participants
    }

    /// The conversation's title: its display name, else its participants, named in order.
    ///
    /// Same rule as `ConversationDirectory.Conversation.title`, which is what the app's
    /// picker shows, so the title a person chose a chat by is the title on the file they get.
    public var title: String {
      if let displayName, !displayName.isEmpty { return displayName }
      guard !participants.isEmpty else { return guid }
      return participants.map(\.displayName).joined(separator: ", ")
    }
  }

  /// A file that travelled with a message.
  public struct Attachment: Sendable, Equatable {
    public var guid: String
    /// The name the sender's device gave the file.
    public var name: String?
    public var mimeType: String?
    public var byteSize: Int64
    public var width: Int?
    public var height: Int?
    public var isSticker: Bool
    /// Where the file was written INSIDE the export, relative to the transcript file. Nil
    /// when the export does not carry files, or when this one could not be copied.
    public var exportedPath: String?
    /// True when the row exists and the file does not: purged to iCloud and not downloaded.
    public var isMissing: Bool

    public init(
      guid: String, name: String? = nil, mimeType: String? = nil, byteSize: Int64 = 0,
      width: Int? = nil, height: Int? = nil, isSticker: Bool = false,
      exportedPath: String? = nil, isMissing: Bool = false
    ) {
      self.guid = guid
      self.name = name
      self.mimeType = mimeType
      self.byteSize = byteSize
      self.width = width
      self.height = height
      self.isSticker = isSticker
      self.exportedPath = exportedPath
      self.isMissing = isMissing
    }
  }

  /// A tapback or emoji reaction. Its own message row in `chat.db`, and its own row here.
  public struct Reaction: Sendable, Equatable {
    /// The reference's wire spelling: `love`, `like`, `dislike`, `laugh`, `emphasize`,
    /// `question`, `emoji`, or any of those with a leading `-` for a removal; an unknown
    /// type is its number as a string.
    public var type: String
    /// The emoji of an emoji tapback, when the row carries one.
    public var emoji: String?
    /// The message the reaction is on.
    public var targetGUID: String
    public var targetPart: Int
    /// The target's words, or a description of its attachments, for the readable formats.
    public var targetSummary: String?

    public init(
      type: String, emoji: String? = nil, targetGUID: String, targetPart: Int = 0,
      targetSummary: String? = nil
    ) {
      self.type = type
      self.emoji = emoji
      self.targetGUID = targetGUID
      self.targetPart = targetPart
      self.targetSummary = targetSummary
    }

    public var isRemoval: Bool { type.hasPrefix("-") }
  }

  /// Something that happened to the conversation rather than something said in it.
  public struct GroupEvent: Sendable, Equatable {
    /// `message.item_type`: 1 participant change, 2 rename, 3 leave or photo, 4 location,
    /// 5 kept audio, 6 FaceTime.
    public var itemType: Int
    /// `message.group_action_type`, which qualifies `itemType`.
    public var groupActionType: Int
    /// The name given on a rename; nil when the name was removed.
    public var groupTitle: String?
    /// The person added or removed, when the event is about somebody else.
    public var other: Participant?

    public init(
      itemType: Int, groupActionType: Int = 0, groupTitle: String? = nil,
      other: Participant? = nil
    ) {
      self.itemType = itemType
      self.groupActionType = groupActionType
      self.groupTitle = groupTitle
      self.other = other
    }
  }

  /// A rich link preview: what Messages shows for a bare URL.
  public struct Link: Sendable, Equatable {
    public var url: String?
    public var title: String?
    public var summary: String?
    public var siteName: String?

    public init(
      url: String? = nil, title: String? = nil, summary: String? = nil, siteName: String? = nil
    ) {
      self.url = url
      self.title = title
      self.summary = summary
      self.siteName = siteName
    }
  }

  /// An iMessage app balloon: Apple Pay, Game Pigeon, a poll, a YouTube card, a rich link.
  public struct Balloon: Sendable, Equatable {
    /// `message.balloon_bundle_id` as stored: `<provider>` or `<provider>:<extension>`.
    public var bundleID: String
    /// The app's own name, from the payload.
    public var appName: String?
    /// The template layout's fields, when the payload carried them.
    public var caption: String?
    public var subcaption: String?
    public var secondarySubcaption: String?
    public var imageTitle: String?
    public var imageSubtitle: String?
    /// The payload's one-line summary (`ldtext`).
    public var summary: String?
    /// The app's payload URL, for a consumer that understands the app.
    public var url: String?
    /// The preview, when the balloon is a rich link.
    public var link: Link?

    public init(
      bundleID: String, appName: String? = nil, caption: String? = nil,
      subcaption: String? = nil, secondarySubcaption: String? = nil, imageTitle: String? = nil,
      imageSubtitle: String? = nil, summary: String? = nil, url: String? = nil,
      link: Link? = nil
    ) {
      self.bundleID = bundleID
      self.appName = appName
      self.caption = caption
      self.subcaption = subcaption
      self.secondarySubcaption = secondarySubcaption
      self.imageTitle = imageTitle
      self.imageSubtitle = imageSubtitle
      self.summary = summary
      self.url = url
      self.link = link
    }
  }

  /// One earlier version of an edited message.
  public struct Edit: Sendable, Equatable {
    public var date: Date?
    public var text: String

    public init(date: Date? = nil, text: String) {
      self.date = date
      self.text = text
    }
  }

  /// What a row IS, which decides how it reads.
  public enum Kind: Sendable, Equatable {
    /// Words, attachments, or both.
    case message
    case groupEvent(GroupEvent)
    case reaction(Reaction)
    case balloon(Balloon)
  }

  public struct Message: Sendable, Equatable {
    public var guid: String
    public var date: Date?
    public var dateDelivered: Date?
    public var dateRead: Date?
    public var dateEdited: Date?
    public var dateRetracted: Date?
    public var isFromMe: Bool
    /// Who sent it. Nil for this Mac's own account, and for a row with no handle.
    public var sender: Participant?
    public var kind: Kind
    public var text: String?
    public var subject: String?
    public var attachments: [Attachment]
    /// Earlier versions, oldest first. Empty for a message that was never edited.
    public var edits: [Edit]
    /// True when the message was unsent: its words are gone and only the fact remains.
    public var isUnsent: Bool
    /// The message this one replies to, when it is a threaded reply.
    public var replyToGUID: String?
    /// The bubble effect the sender chose (`expressive_send_style_id`), when any.
    public var effect: String?
    public var service: String?
    public var isAudioMessage: Bool
    /// `message.error`: non-zero means Messages failed to send it.
    public var error: Int

    public init(
      guid: String, date: Date? = nil, dateDelivered: Date? = nil, dateRead: Date? = nil,
      dateEdited: Date? = nil, dateRetracted: Date? = nil, isFromMe: Bool,
      sender: Participant? = nil, kind: Kind = .message, text: String? = nil,
      subject: String? = nil, attachments: [Attachment] = [], edits: [Edit] = [],
      isUnsent: Bool = false, replyToGUID: String? = nil, effect: String? = nil,
      service: String? = nil, isAudioMessage: Bool = false, error: Int = 0
    ) {
      self.guid = guid
      self.date = date
      self.dateDelivered = dateDelivered
      self.dateRead = dateRead
      self.dateEdited = dateEdited
      self.dateRetracted = dateRetracted
      self.isFromMe = isFromMe
      self.sender = sender
      self.kind = kind
      self.text = text
      self.subject = subject
      self.attachments = attachments
      self.edits = edits
      self.isUnsent = isUnsent
      self.replyToGUID = replyToGUID
      self.effect = effect
      self.service = service
      self.isAudioMessage = isAudioMessage
      self.error = error
    }
  }

  /// Whether, and how, attachments travel with the transcript.
  public enum AttachmentMode: String, Sendable, Equatable, CaseIterable, Codable {
    /// Counted and typed ("1 Photo"), and nothing more: no names, no sizes, no files.
    case none
    /// Name, type and size, read from the row; nothing is copied.
    case metadata
    /// The files themselves, copied beside the transcript and named from it.
    case files
  }

  /// Everything the writers need before the first message.
  public struct Header: Sendable, Equatable {
    public var chat: Chat
    public var format: TranscriptFormat
    public var attachmentMode: AttachmentMode
    /// The window that was asked for. Nil means unbounded on that side.
    public var after: Date?
    public var before: Date?
    /// The zone every readable date is written in.
    public var timeZone: TimeZone
    /// How this Mac's own messages are labelled.
    public var meLabel: String
    public var exportedAt: Date
    /// What produced the file, for the footer and the JSON `generator` field.
    public var generator: String

    public init(
      chat: Chat, format: TranscriptFormat, attachmentMode: AttachmentMode,
      after: Date? = nil, before: Date? = nil, timeZone: TimeZone = .current,
      meLabel: String = Transcript.defaultMeLabel, exportedAt: Date = Date(),
      generator: String
    ) {
      self.chat = chat
      self.format = format
      self.attachmentMode = attachmentMode
      self.after = after
      self.before = before
      self.timeZone = timeZone
      self.meLabel = meLabel
      self.exportedAt = exportedAt
      self.generator = generator
    }
  }

  /// What was written, counted as it went.
  public struct Summary: Sendable, Equatable {
    public var messageCount: Int
    public var reactionCount: Int
    public var attachmentCount: Int
    /// Files actually placed in the export. Zero unless the mode is `.files`.
    public var attachmentsCopied: Int
    /// Rows whose file was not on disk.
    public var attachmentsMissing: Int
    public var firstMessageDate: Date?
    public var lastMessageDate: Date?

    public init(
      messageCount: Int = 0, reactionCount: Int = 0, attachmentCount: Int = 0,
      attachmentsCopied: Int = 0, attachmentsMissing: Int = 0, firstMessageDate: Date? = nil,
      lastMessageDate: Date? = nil
    ) {
      self.messageCount = messageCount
      self.reactionCount = reactionCount
      self.attachmentCount = attachmentCount
      self.attachmentsCopied = attachmentsCopied
      self.attachmentsMissing = attachmentsMissing
      self.firstMessageDate = firstMessageDate
      self.lastMessageDate = lastMessageDate
    }

    /// Folds one written message into the totals.
    public mutating func record(_ message: Message) {
      messageCount += 1
      if case .reaction = message.kind { reactionCount += 1 }
      attachmentCount += message.attachments.count
      attachmentsCopied += message.attachments.filter { $0.exportedPath != nil }.count
      attachmentsMissing += message.attachments.filter(\.isMissing).count
      if let date = message.date {
        if firstMessageDate.map({ date < $0 }) ?? true { firstMessageDate = date }
        if lastMessageDate.map({ date > $0 }) ?? true { lastMessageDate = date }
      }
    }
  }

  /// The label for this Mac's own messages when the caller does not choose one.
  public static let defaultMeLabel = "Me"
}

/// The file shapes a transcript can take.
public enum TranscriptFormat: String, Sendable, Equatable, CaseIterable, Codable {
  /// Every field, for another program. The canonical shape; the other two are views of it.
  case json
  /// One line per message, for reading and for grep.
  case txt
  /// A self-contained page with bubbles, for reading in a browser and for printing.
  case html

  public var fileExtension: String { rawValue }

  public var contentType: String {
    switch self {
    case .json: "application/json; charset=utf-8"
    case .txt: "text/plain; charset=utf-8"
    case .html: "text/html; charset=utf-8"
    }
  }

  /// What a picker shows.
  public var title: String {
    switch self {
    case .json: "JSON"
    case .txt: "Plain text"
    case .html: "HTML page"
    }
  }
}
