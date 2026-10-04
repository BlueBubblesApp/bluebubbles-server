//  MessageDescription
//  One sentence for anything a transcript row can be, in the words the BlueBubbles client
//  uses for the same thing.
//
//  A transcript is read by somebody who was in the conversation, and every row that is not
//  plain text has to read the way their phone showed it: "Alice loved “see you at 6”",
//  "Bob named the conversation "Team"", "Apple Pay: $20.00", "1 Photo". Those sentences are
//  transcribed from the client's own rendering code so the export and the app agree:
//
//  - group events: `message.dart` `buildGroupEventText`
//  - reactions: `reaction_helpers.dart` `ReactionTypes.reactionToVerb`
//  - attachments: `extensions.dart` `_getAttachmentText`
//  - balloons: `constants.dart` `balloonBundleIdMap`, `message.dart` `interactiveText`, and
//    the per-app widgets under `widgets/message/interactive/`
//  - unsent and invisible-ink rows: `chat_event.dart` and `getNotificationText`
//
//  Each is a pure function of the model, so `MessageDescriptionTests` can hold every
//  sentence against a value. The three writers call `TranscriptLine.describe` and never
//  decide any of this themselves.

import Foundation

/// The balloon providers and iMessage extensions the client names, keyed as `chat.db`
/// spells them. Anything else reads as its extension's bundle identifier.
public enum BalloonCatalog {

  /// Apple's built-in balloon providers, which are not iMessage apps.
  static let providers: [String: String] = [
    "com.apple.Handwriting.HandwritingProvider": "Handwritten Message",
    "com.apple.DigitalTouchBalloonProvider": "Digital Touch Message",
    "com.apple.messages.URLBalloonProvider": "Link",
  ]

  /// Extensions under `com.apple.messages.MSMessageExtensionBalloonPlugin`.
  ///
  /// Transcribed from the client's `balloonBundleIdMap`, spelling corrected where the
  /// client's is a typo ("Handwriten"). An extension not listed here is still rendered: its
  /// identifier is shown, which is more use than "Unknown".
  static let extensions: [String: String] = [
    "com.nearfuturespecialists.imessagepoll.MessagesExtension": "iMessage Poll",
    "be.nieldeckx.poll.extension": "iMessage Poll",
    "com.gamerdelights.gamepigeon.ext": "GamePigeon",
    "com.google.ios.youtube.MessagesExtension": "YouTube",
    "com.shazam.Shazam.imessageextension": "Shazam",
    "com.apple.mobileslideshow.PhotosMessagesApp": "Photo Slideshow",
    "com.contextoptional.OpenTable.Messages": "OpenTable",
    "com.apple.PassbookUIService.PeerPaymentMessagesExtension": "Apple Pay",
    "com.apple.icloud.apps.messages.business.extension": "Business Interactive Message",
    "com.google.Maps.MessagesExtension": "Google Maps",
    "com.apple.messages.polls": "Poll",
  ]

  public static let extensionPlugin = "com.apple.messages.MSMessageExtensionBalloonPlugin"
  public static let richLinkProvider = "com.apple.messages.URLBalloonProvider"

  /// The provider half of a bundle id: everything before the first colon.
  public static func provider(of bundleID: String) -> String {
    String(bundleID.split(separator: ":", maxSplits: 1).first ?? Substring(bundleID))
  }

  /// The extension half, when there is one.
  public static func extensionID(of bundleID: String) -> String? {
    let parts = bundleID.split(separator: ":", maxSplits: 1)
    return parts.count == 2 ? String(parts[1]) : nil
  }

  /// A readable name for the balloon's app, the way the client shows it.
  public static func name(forBundleID bundleID: String, appName: String? = nil) -> String {
    let provider = provider(of: bundleID)
    if let known = providers[provider] { return known }
    if let extensionID = extensionID(of: bundleID) {
      if let known = extensions[extensionID] { return known }
      if let appName, !appName.isEmpty { return appName }
      return extensionID
    }
    if let appName, !appName.isEmpty { return appName }
    return provider
  }

  public static func isRichLink(_ bundleID: String) -> Bool {
    provider(of: bundleID) == richLinkProvider
  }
}

/// The sentence a group event reads as, transcribed from the client.
public enum GroupEventText {

  /// - Parameters:
  ///   - actor: who did it, already resolved ("You", a name, an address).
  ///   - isMe: whether the actor is this Mac's own account; changes "their" to "your".
  public static func describe(_ event: Transcript.GroupEvent, actor: String, isMe: Bool)
    -> String
  {
    let other = event.other?.displayName ?? "someone"
    switch (event.itemType, event.groupActionType) {
    case (1, 0): return "\(actor) added \(other) to the conversation."
    case (1, 1): return "\(actor) removed \(other) from the conversation."
    case (2, _):
      if let title = event.groupTitle, !title.isEmpty {
        return "\(actor) named the conversation \"\(title)\"."
      }
      return "\(actor) removed the name from the conversation."
    case (3, 1): return "\(actor) changed the group photo."
    case (3, 2): return "\(actor) removed the group photo."
    case (3, _): return "\(actor) left the conversation."
    case (4, 0): return "\(actor) shared \(isMe ? "your" : "their") location."
    case (5, _): return "\(actor) kept an audio message."
    case (6, _): return "\(actor) started a FaceTime call."
    default: return "Unknown group event."
    }
  }
}

/// How a reaction reads, transcribed from the client's `reactionToVerb`.
public enum ReactionText {

  static let verbs: [String: String] = [
    "love": "loved", "like": "liked", "dislike": "disliked", "laugh": "laughed at",
    "emphasize": "emphasised", "question": "questioned",
    "-love": "removed a heart from", "-like": "removed a like from",
    "-dislike": "removed a dislike from", "-laugh": "removed a laugh from",
    "-emphasize": "removed an exclamation from", "-question": "removed a question mark from",
  ]

  static let emoji: [String: String] = [
    "love": "❤️", "like": "👍", "dislike": "👎", "laugh": "😂", "emphasize": "❗",
    "question": "❓",
  ]

  /// The verb for a reaction type. An emoji tapback reads as the emoji itself.
  public static func verb(for reaction: Transcript.Reaction) -> String {
    if let known = verbs[reaction.type] { return known }
    let bare = reaction.type.hasPrefix("-") ? String(reaction.type.dropFirst()) : reaction.type
    if bare == "emoji" {
      let symbol = reaction.emoji ?? "an emoji"
      return reaction.isRemoval ? "removed \(symbol) from" : "reacted \(symbol) to"
    }
    return reaction.isRemoval ? "removed a reaction from" : "reacted to"
  }

  /// The symbol a tapback type draws, for the HTML rendering.
  public static func symbol(for reaction: Transcript.Reaction) -> String? {
    if let emoji = reaction.emoji, !emoji.isEmpty { return emoji }
    let bare = reaction.type.hasPrefix("-") ? String(reaction.type.dropFirst()) : reaction.type
    return emoji[bare]
  }

  /// "Alice loved “hello”", or "Alice loved 1 Photo" when the target had no words.
  public static func describe(_ reaction: Transcript.Reaction, actor: String) -> String {
    let verb = verb(for: reaction)
    guard let summary = reaction.targetSummary, !summary.isEmpty else {
      return "\(actor) \(verb) a message"
    }
    return "\(actor) \(verb) “\(summary)”"
  }
}

/// "1 Photo", "2 Videos & 1 Audio message": the client's `_getAttachmentText`.
public enum AttachmentText {

  /// The noun for one attachment.
  public static func noun(for attachment: Transcript.Attachment) -> String {
    if attachment.isSticker { return "Sticker" }
    guard let mime = attachment.mimeType, !mime.isEmpty else { return "Link" }
    if mime.contains("vcard") { return "Contact card" }
    if mime.contains("location") { return "Location" }
    if mime.contains("contact") { return "Contact" }
    if mime.contains("video") { return "Video" }
    if mime.contains("audio") { return "Audio message" }
    if mime.contains("image/gif") { return "GIF" }
    if mime.contains("image") { return "Photo" }
    if mime.contains("application/pdf") { return "PDF" }
    let family = mime.split(separator: "/").first.map(String.init) ?? ""
    return family.isEmpty ? "File" : family.prefix(1).uppercased() + family.dropFirst()
  }

  /// The counted list. Empty input reads as an empty string.
  public static func describe(_ attachments: [Transcript.Attachment]) -> String {
    var counts: [(noun: String, count: Int)] = []
    for attachment in attachments {
      let noun = noun(for: attachment)
      if let index = counts.firstIndex(where: { $0.noun == noun }) {
        counts[index].count += 1
      } else {
        counts.append((noun, 1))
      }
      // A message carries at most one link preview however many rows describe it.
      if noun == "Link" { break }
    }
    let phrases = counts.map { "\($0.count) \($0.noun)\($0.count > 1 ? "s" : "")" }
    return phrases.joined(separator: phrases.count == 2 ? " & " : ", ")
  }
}

/// What an app balloon says, transcribed from the client's per-app widgets.
public enum BalloonText {

  /// The app's name as a reader knows it.
  public static func title(for balloon: Transcript.Balloon) -> String {
    BalloonCatalog.name(forBundleID: balloon.bundleID, appName: balloon.appName)
  }

  /// The balloon's content in one line, without its title.
  ///
  /// - A rich link: the page title and its host, which is what the client's
  ///   `interactiveText` shows ("Website: Title (host)").
  /// - Apple Pay: the subcaption, which carries the amount or the request.
  /// - Game Pigeon: the caption, which names the game and the move.
  /// - Anything else: the caption, else the summary, then the subcaptions.
  public static func body(for balloon: Transcript.Balloon) -> String? {
    if let link = balloon.link {
      var pieces: [String] = []
      if let title = link.title, !title.isEmpty { pieces.append(title) }
      if let host = link.url.flatMap(URL.init(string:))?.host {
        pieces.append("(\(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host))")
      } else if let url = link.url, !url.isEmpty {
        pieces.append(url)
      }
      return pieces.isEmpty ? nil : pieces.joined(separator: " ")
    }
    var pieces: [String] = []
    for piece in [
      balloon.caption, balloon.summary, balloon.imageTitle, balloon.imageSubtitle,
      balloon.secondarySubcaption, balloon.subcaption,
    ] {
      if let piece, !piece.isEmpty, !pieces.contains(piece) { pieces.append(piece) }
    }
    return pieces.isEmpty ? nil : pieces.joined(separator: " — ")
  }

  /// "Apple Pay: $20.00", "GamePigeon: 8 Ball", "Link: Example Domain (example.com)".
  public static func describe(_ balloon: Transcript.Balloon) -> String {
    let title = title(for: balloon)
    guard let body = body(for: balloon) else { return title }
    return "\(title): \(body)"
  }
}

/// The one line a message reads as in the plain-text transcript, and the pieces the HTML
/// page lays out separately.
public enum TranscriptLine {

  /// What invisible ink reads as; the words are deliberately not shown, as on the client.
  static let invisibleInkStyle = "com.apple.MobileSMS.expressivesend.invisibleink"

  /// Who the row is from, as a reader sees it.
  public static func actor(for message: Transcript.Message, header: Transcript.Header) -> String {
    if message.isFromMe { return header.meLabel }
    return message.sender?.displayName ?? "Unknown"
  }

  /// The row's content, without the sender or the time.
  ///
  /// Nil only for a row that has nothing at all to say, which the writers still print as an
  /// empty message so the count stays honest.
  public static func body(for message: Transcript.Message, header: Transcript.Header) -> String? {
    let actor = actor(for: message, header: header)
    switch message.kind {
    case .groupEvent(let event):
      return GroupEventText.describe(event, actor: actor, isMe: message.isFromMe)
    case .reaction(let reaction):
      return ReactionText.describe(reaction, actor: actor)
    case .balloon(let balloon):
      return BalloonText.describe(balloon)
    case .message:
      break
    }
    if message.isUnsent {
      return message.isFromMe
        ? "\(header.meLabel) unsent a message." : "\(actor) unsent a message."
    }
    if message.effect == invisibleInkStyle {
      return "Message sent with Invisible Ink"
    }
    var pieces: [String] = []
    if let subject = message.subject, !subject.isEmpty { pieces.append(subject) }
    if let text = message.text, !text.isEmpty { pieces.append(text) }
    if !message.attachments.isEmpty, header.attachmentMode != .none {
      pieces.append(attachmentLine(message.attachments))
    } else if !message.attachments.isEmpty {
      pieces.append(AttachmentText.describe(message.attachments))
    }
    guard !pieces.isEmpty else {
      return message.dateEdited != nil ? "Unsent message" : "Empty message"
    }
    return pieces.joined(separator: "\n")
  }

  /// "1 Photo (IMG_0001.heic)" or "2 Photos (a.jpg, b.jpg)", naming the files beside the
  /// count so a reader can find them in the export.
  static func attachmentLine(_ attachments: [Transcript.Attachment]) -> String {
    let counted = AttachmentText.describe(attachments)
    let names = attachments.compactMap { attachment -> String? in
      let name = attachment.exportedPath ?? attachment.name
      guard let name, !name.isEmpty else { return nil }
      return attachment.isMissing ? "\(name), not on this Mac" : name
    }
    return names.isEmpty ? counted : "\(counted) (\(names.joined(separator: ", ")))"
  }

  /// A one-line account of what a message said, for quoting under a reaction.
  public static func summary(for message: Transcript.Message, header: Transcript.Header)
    -> String?
  {
    switch message.kind {
    case .balloon(let balloon): return BalloonText.describe(balloon)
    case .groupEvent, .reaction: return nil
    case .message: break
    }
    if let text = message.text, !text.isEmpty { return text }
    if !message.attachments.isEmpty { return AttachmentText.describe(message.attachments) }
    if let subject = message.subject, !subject.isEmpty { return subject }
    return nil
  }

  /// Whether the row is an event line rather than a bubble: group events, reactions,
  /// unsends. The HTML writer centres these.
  public static func isEvent(_ message: Transcript.Message) -> Bool {
    switch message.kind {
    case .groupEvent, .reaction: return true
    case .balloon: return false
    case .message: return message.isUnsent
    }
  }
}
