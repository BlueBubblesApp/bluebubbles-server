//  TranscriptWriters
//  The three renderings of a transcript, each streamed one message at a time.
//
//  One protocol, three writers, and one rule: a writer formats, it never decides. Who a row
//  is from and what it says come from `TranscriptLine`; a writer only lays the answer out.
//  That is what keeps the plain-text line, the HTML bubble and the JSON object describing
//  the same reaction with the same words.
//
//  `begin` is called once with the header, `write` once per message in the order the
//  interface read them (oldest first), and `finish` once with the totals. A writer holds no
//  message after returning from `write`: the file is the record, not the object, which is
//  what bounds the export's memory to one page of rows however long the conversation is.

import Foundation

public protocol TranscriptWriter: AnyObject {
  init(output: TranscriptOutput)
  func begin(_ header: Transcript.Header) throws
  func write(_ message: Transcript.Message) throws
  func finish(_ summary: Transcript.Summary) throws
}

extension TranscriptFormat {
  /// The writer for this format.
  public func makeWriter(output: TranscriptOutput) -> any TranscriptWriter {
    switch self {
    case .json: JSONTranscriptWriter(output: output)
    case .txt: PlainTextTranscriptWriter(output: output)
    case .html: HTMLTranscriptWriter(output: output)
    }
  }
}

/// Readable dates, in the export's zone. One formatter per writer, built from the header.
struct TranscriptDates {
  let timestamp: DateFormatter
  let day: DateFormatter
  let iso: ISO8601DateFormatter

  init(timeZone: TimeZone) {
    timestamp = DateFormatter()
    timestamp.locale = Locale(identifier: "en_US_POSIX")
    timestamp.timeZone = timeZone
    timestamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
    day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.timeZone = timeZone
    day.dateFormat = "EEEE, d MMMM yyyy"
    iso = ISO8601DateFormatter()
    iso.timeZone = timeZone
    iso.formatOptions = [.withInternetDateTime]
  }

  func stamp(_ date: Date?) -> String {
    date.map(timestamp.string(from:)) ?? "unknown time"
  }

  /// The day a date falls in, so a writer can tell when one changes.
  func dayKey(_ date: Date?) -> String? {
    date.map(day.string(from:))
  }

  /// The window, or what is open about it.
  func range(after: Date?, before: Date?) -> String {
    switch (after, before) {
    case (nil, nil): "every message"
    case (let after?, nil): "from \(stamp(after))"
    case (nil, let before?): "up to \(stamp(before))"
    case (let after?, let before?): "\(stamp(after)) to \(stamp(before))"
    }
  }
}

// MARK: - JSON

/// The canonical rendering: every field, keys in `snake_case`, dates twice.
///
/// Dates carry an epoch-millisecond integer (`date`) for a program and an ISO 8601 string
/// in the export's zone (`date_iso`) for a person reading the file, because a JSON
/// transcript is opened in an editor at least as often as it is parsed.
///
/// Written as a hand-framed object (`{ … "messages": [` … `], "summary": … }`) with each
/// message serialised on its own, so the file grows as it is written rather than being
/// built in memory and dumped. `schema_version` is bumped when a field changes meaning; an
/// added field is not a bump.
public final class JSONTranscriptWriter: TranscriptWriter {

  public static let schemaVersion = 1

  private let output: TranscriptOutput
  private var dates = TranscriptDates(timeZone: .current)
  private var isFirstMessage = true

  public init(output: TranscriptOutput) {
    self.output = output
  }

  public func begin(_ header: Transcript.Header) throws {
    dates = TranscriptDates(timeZone: header.timeZone)
    let head: [String: Any] = [
      "schema_version": Self.schemaVersion,
      "generator": header.generator,
      "format": header.format.rawValue,
      "exported_at": epoch(header.exportedAt),
      "exported_at_iso": dates.iso.string(from: header.exportedAt),
      "time_zone": header.timeZone.identifier,
      "me_label": header.meLabel,
      "attachment_mode": header.attachmentMode.rawValue,
      "range": [
        "after": header.after.map(epoch) ?? NSNull(),
        "after_iso": header.after.map(dates.iso.string(from:)) ?? NSNull(),
        "before": header.before.map(epoch) ?? NSNull(),
        "before_iso": header.before.map(dates.iso.string(from:)) ?? NSNull(),
      ] as [String: Any],
      "chat": chat(header.chat),
    ]
    var framed = try Self.encode(head)
    // Drop the closing brace so the message array and the summary can follow inside.
    framed.removeLast()
    try output.write(framed)
    try output.write(",\"messages\":[\n")
  }

  public func write(_ message: Transcript.Message) throws {
    if !isFirstMessage { try output.write(",\n") }
    isFirstMessage = false
    try output.write(try Self.encode(object(for: message)))
  }

  public func finish(_ summary: Transcript.Summary) throws {
    try output.write("\n],\"summary\":")
    try output.write(
      try Self.encode([
        "message_count": summary.messageCount,
        "reaction_count": summary.reactionCount,
        "attachment_count": summary.attachmentCount,
        "attachments_copied": summary.attachmentsCopied,
        "attachments_missing": summary.attachmentsMissing,
        "first_message_date": summary.firstMessageDate.map(epoch) ?? NSNull(),
        "first_message_date_iso": summary.firstMessageDate.map(dates.iso.string(from:))
          ?? NSNull(),
        "last_message_date": summary.lastMessageDate.map(epoch) ?? NSNull(),
        "last_message_date_iso": summary.lastMessageDate.map(dates.iso.string(from:))
          ?? NSNull(),
      ]))
    try output.write("}\n")
    try output.close()
  }

  // MARK: Objects

  private func epoch(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded(.towardZero))
  }

  private func dateFields(_ date: Date?, key: String) -> [String: Any] {
    [key: date.map(epoch) ?? NSNull(), "\(key)_iso": date.map(dates.iso.string(from:)) ?? NSNull()]
  }

  private func participant(_ participant: Transcript.Participant) -> [String: Any] {
    [
      "address": participant.address,
      "service": participant.service ?? NSNull(),
      "name": participant.name ?? NSNull(),
      "name_source": participant.nameSource.rawValue,
      "display_name": participant.displayName,
    ]
  }

  private func chat(_ chat: Transcript.Chat) -> [String: Any] {
    [
      "guid": chat.guid,
      "display_name": chat.displayName ?? NSNull(),
      "title": chat.title,
      "is_group": chat.isGroup,
      "service": chat.service ?? NSNull(),
      "participants": chat.participants.map(participant),
    ]
  }

  private func attachment(_ attachment: Transcript.Attachment) -> [String: Any] {
    [
      "guid": attachment.guid,
      "name": attachment.name ?? NSNull(),
      "mime_type": attachment.mimeType ?? NSNull(),
      "byte_size": attachment.byteSize,
      "width": attachment.width ?? NSNull(),
      "height": attachment.height ?? NSNull(),
      "is_sticker": attachment.isSticker,
      "path": attachment.exportedPath ?? NSNull(),
      "is_missing": attachment.isMissing,
    ]
  }

  private func object(for message: Transcript.Message) -> [String: Any] {
    var object: [String: Any] = [
      "guid": message.guid,
      "is_from_me": message.isFromMe,
      "sender": message.sender.map(participant) ?? NSNull(),
      "text": message.text ?? NSNull(),
      "subject": message.subject ?? NSNull(),
      "attachments": message.attachments.map(attachment),
      "is_unsent": message.isUnsent,
      "reply_to_guid": message.replyToGUID ?? NSNull(),
      "effect": message.effect ?? NSNull(),
      "service": message.service ?? NSNull(),
      "is_audio_message": message.isAudioMessage,
      "error": message.error,
      "edits": message.edits.map { edit -> [String: Any] in
        var fields = dateFields(edit.date, key: "date")
        fields["text"] = edit.text
        return fields
      },
    ]
    for (key, value) in dateFields(message.date, key: "date") { object[key] = value }
    for (key, value) in dateFields(message.dateDelivered, key: "date_delivered") {
      object[key] = value
    }
    for (key, value) in dateFields(message.dateRead, key: "date_read") { object[key] = value }
    for (key, value) in dateFields(message.dateEdited, key: "date_edited") { object[key] = value }
    for (key, value) in dateFields(message.dateRetracted, key: "date_retracted") {
      object[key] = value
    }
    switch message.kind {
    case .message:
      object["kind"] = "message"
    case .groupEvent(let event):
      object["kind"] = "group_event"
      object["group_event"] = [
        "item_type": event.itemType,
        "group_action_type": event.groupActionType,
        "group_title": event.groupTitle ?? NSNull(),
        "other": event.other.map(participant) ?? NSNull(),
        "description": GroupEventText.describe(
          event, actor: message.isFromMe ? "You" : (message.sender?.displayName ?? "Unknown"),
          isMe: message.isFromMe),
      ] as [String: Any]
    case .reaction(let reaction):
      object["kind"] = "reaction"
      object["reaction"] = [
        "type": reaction.type,
        "emoji": reaction.emoji ?? NSNull(),
        "target_guid": reaction.targetGUID,
        "target_part": reaction.targetPart,
        "target_summary": reaction.targetSummary ?? NSNull(),
        "is_removal": reaction.isRemoval,
      ] as [String: Any]
    case .balloon(let balloon):
      object["kind"] = "balloon"
      var fields: [String: Any] = [
        "bundle_id": balloon.bundleID,
        "app_name": balloon.appName ?? NSNull(),
        "title": BalloonText.title(for: balloon),
        "caption": balloon.caption ?? NSNull(),
        "subcaption": balloon.subcaption ?? NSNull(),
        "secondary_subcaption": balloon.secondarySubcaption ?? NSNull(),
        "image_title": balloon.imageTitle ?? NSNull(),
        "image_subtitle": balloon.imageSubtitle ?? NSNull(),
        "summary": balloon.summary ?? NSNull(),
        "url": balloon.url ?? NSNull(),
        "description": BalloonText.describe(balloon),
      ]
      if let link = balloon.link {
        fields["link"] =
          [
            "url": link.url ?? NSNull(),
            "title": link.title ?? NSNull(),
            "summary": link.summary ?? NSNull(),
            "site_name": link.siteName ?? NSNull(),
          ] as [String: Any]
      }
      object["balloon"] = fields
    }
    return object
  }

  /// One object, keys sorted so two exports of the same conversation are byte-identical.
  static func encode(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
  }
}

// MARK: - Plain text

/// One line per message: `[time] Sender: text`, with a day heading when the day changes.
///
/// Text with line breaks keeps them, indented under the first line so a grep for the
/// timestamp prefix still finds one row per message.
public final class PlainTextTranscriptWriter: TranscriptWriter {

  private let output: TranscriptOutput
  private var header: Transcript.Header?
  private var dates = TranscriptDates(timeZone: .current)
  private var currentDay: String?

  public init(output: TranscriptOutput) {
    self.output = output
  }

  public func begin(_ header: Transcript.Header) throws {
    self.header = header
    dates = TranscriptDates(timeZone: header.timeZone)
    let chat = header.chat
    var lines: [String] = []
    lines.append("Conversation: \(chat.title)")
    lines.append(
      "Kind: \(chat.isGroup ? "group" : "direct")\(chat.service.map { " (\($0))" } ?? "")")
    if !chat.participants.isEmpty {
      lines.append("Participants:")
      for participant in chat.participants {
        lines.append("  - \(Self.describe(participant))")
      }
    }
    lines.append("Range: \(dates.range(after: header.after, before: header.before))")
    lines.append("Time zone: \(header.timeZone.identifier)")
    lines.append("Exported: \(dates.stamp(header.exportedAt)) by \(header.generator)")
    try output.write(lines.joined(separator: "\n") + "\n\n")
  }

  public func write(_ message: Transcript.Message) throws {
    guard let header else { return }
    if let day = dates.dayKey(message.date), day != currentDay {
      currentDay = day
      try output.write("---- \(day) ----\n")
    }
    let stamp = dates.stamp(message.date)
    let body = TranscriptLine.body(for: message, header: header) ?? ""
    let line: String
    if TranscriptLine.isEvent(message) {
      line = "[\(stamp)] — \(body)"
    } else {
      let actor = TranscriptLine.actor(for: message, header: header)
      line = "[\(stamp)] \(actor): \(body)"
    }
    try output.write(Self.indentContinuations(line) + "\n")
    for edit in message.edits {
      try output.write("    (earlier version, \(dates.stamp(edit.date)): \(edit.text))\n")
    }
    if message.error != 0 {
      try output.write("    (not delivered: Messages reported error \(message.error))\n")
    }
  }

  public func finish(_ summary: Transcript.Summary) throws {
    var lines = ["", "----"]
    lines.append("Messages: \(summary.messageCount)")
    lines.append("Reactions: \(summary.reactionCount)")
    lines.append("Attachments: \(summary.attachmentCount)")
    if summary.attachmentsCopied > 0 {
      lines.append("Attachments included: \(summary.attachmentsCopied)")
    }
    if summary.attachmentsMissing > 0 {
      lines.append("Attachments not on this Mac: \(summary.attachmentsMissing)")
    }
    if let first = summary.firstMessageDate, let last = summary.lastMessageDate {
      lines.append("Spanning: \(dates.stamp(first)) to \(dates.stamp(last))")
    }
    try output.write(lines.joined(separator: "\n") + "\n")
    try output.close()
  }

  static func describe(_ participant: Transcript.Participant) -> String {
    let name = participant.displayName
    guard let real = participant.name, !real.isEmpty else { return name }
    return "\(real) (\(participant.address))"
  }

  /// Keeps a multi-line body under its own timestamp.
  static func indentContinuations(_ line: String) -> String {
    line.split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
      .map { $0.offset == 0 ? String($0.element) : "    \($0.element)" }
      .joined(separator: "\n")
  }
}

// MARK: - HTML

/// A self-contained page: bubbles left and right, event lines centred, attachments shown
/// inline when the export carries them. No script, no remote resource, so the file is safe
/// to open from anywhere and renders the same offline.
public final class HTMLTranscriptWriter: TranscriptWriter {

  private let output: TranscriptOutput
  private var header: Transcript.Header?
  private var dates = TranscriptDates(timeZone: .current)
  private var currentDay: String?

  public init(output: TranscriptOutput) {
    self.output = output
  }

  public func begin(_ header: Transcript.Header) throws {
    self.header = header
    dates = TranscriptDates(timeZone: header.timeZone)
    let chat = header.chat
    let title = Self.escape(chat.title)
    let kind = chat.isGroup ? "Group" : "Direct"
    let service = chat.service.map { " on \(Self.escape($0))" } ?? ""
    let range = Self.escape(dates.range(after: header.after, before: header.before))
    let zone = Self.escape(header.timeZone.identifier)
    let items = chat.participants
      .map { "<li>\(Self.escape(PlainTextTranscriptWriter.describe($0)))</li>" }
      .joined()
    let participants = items.isEmpty ? "" : "<ul class=\"participants\">\(items)</ul>\n"
    var page = "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
    page += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
    page += "<title>\(title)</title>\n<style>\(Self.stylesheet)</style>\n</head>\n<body>\n"
    page += "<header>\n<h1>\(title)</h1>\n"
    page += "<p class=\"meta\">\(kind) conversation\(service) · \(range) · times in \(zone)</p>\n"
    page += participants
    page += "</header>\n<main>\n"
    try output.write(page)
  }

  public func write(_ message: Transcript.Message) throws {
    guard let header else { return }
    if let day = dates.dayKey(message.date), day != currentDay {
      currentDay = day
      try output.write("<h2 class=\"day\">\(Self.escape(day))</h2>\n")
    }
    let stamp = Self.escape(dates.stamp(message.date))
    let body = TranscriptLine.body(for: message, header: header) ?? ""
    if TranscriptLine.isEvent(message) {
      try output.write(
        "<div class=\"event\"><time>\(stamp)</time> \(Self.escape(body))</div>\n")
      return
    }
    let actor = Self.escape(TranscriptLine.actor(for: message, header: header))
    let side = message.isFromMe ? "me" : "them"
    var html = "<div class=\"row \(side)\"><div class=\"bubble\">"
    html += "<div class=\"who\">\(actor) <time>\(stamp)</time></div>"
    html += content(of: message, body: body)
    for attachment in message.attachments {
      html += Self.render(attachment)
    }
    if !message.edits.isEmpty {
      html += "<details class=\"edits\"><summary>Edited</summary><ul>"
      for edit in message.edits {
        let when = Self.escape(dates.stamp(edit.date))
        html += "<li><time>\(when)</time> \(Self.escape(edit.text))</li>"
      }
      html += "</ul></details>"
    }
    if message.error != 0 {
      html += "<div class=\"error\">Not delivered (error \(message.error))</div>"
    }
    html += "</div></div>\n"
    try output.write(html)
  }

  public func finish(_ summary: Transcript.Summary) throws {
    guard let header else { return }
    var facts = [
      "\(summary.messageCount) messages", "\(summary.reactionCount) reactions",
      "\(summary.attachmentCount) attachments",
    ]
    if summary.attachmentsMissing > 0 {
      facts.append("\(summary.attachmentsMissing) not on this Mac")
    }
    let exported = Self.escape(dates.stamp(header.exportedAt))
    let generator = Self.escape(header.generator)
    var page = "</main>\n<footer><p>\(Self.escape(facts.joined(separator: " · ")))</p>"
    page += "<p>Exported \(exported) by \(generator)</p></footer>\n</body>\n</html>\n"
    try output.write(page)
    try output.close()
  }

  /// The inside of a bubble: the words, a balloon, or the sentence standing in for them.
  private func content(of message: Transcript.Message, body: String) -> String {
    if case .balloon(let balloon) = message.kind {
      var html = "<div class=\"balloon\"><span class=\"app\">"
      html += Self.escape(BalloonText.title(for: balloon)) + "</span>"
      if let text = BalloonText.body(for: balloon) {
        html += " \(Self.escape(text))"
      }
      if let url = balloon.link?.url ?? balloon.url, url.hasPrefix("http") {
        html += " <a href=\"\(Self.escapeAttribute(url))\">open</a>"
      }
      return html + "</div>"
    }
    var html = ""
    if let subject = message.subject, !subject.isEmpty {
      html += "<div class=\"subject\">\(Self.escape(subject))</div>"
    }
    let hasText = !(message.text?.isEmpty ?? true)
    let isHidden = message.isUnsent || message.effect == TranscriptLine.invisibleInkStyle
    if hasText, !isHidden, let text = message.text {
      html += "<p>\(Self.escape(text).replacingOccurrences(of: "\n", with: "<br>"))</p>"
    } else if isHidden || message.attachments.isEmpty {
      // Unsent, invisible ink, or nothing at all: the sentence the plain-text line shows.
      html += "<p class=\"muted\">\(Self.escape(body))</p>"
    }
    return html
  }

  /// An attachment as a figure: inline when the bytes are beside the page, a name otherwise.
  static func render(_ attachment: Transcript.Attachment) -> String {
    let label = escape(attachment.name ?? AttachmentText.noun(for: attachment))
    guard let path = attachment.exportedPath else {
      let note = attachment.isMissing ? " (not on this Mac)" : ""
      return "<div class=\"attachment\">📎 \(label)\(note)</div>"
    }
    let href = escapeAttribute(path)
    let caption = "<figcaption>\(label)</figcaption></figure>"
    let mime = attachment.mimeType ?? ""
    if mime.hasPrefix("image/") {
      let image = "<img src=\"\(href)\" alt=\"\(label)\" loading=\"lazy\">"
      return "<figure><a href=\"\(href)\">\(image)</a>" + caption
    }
    if mime.hasPrefix("video/") {
      return "<figure><video controls preload=\"metadata\" src=\"\(href)\"></video>" + caption
    }
    if mime.hasPrefix("audio/") {
      return "<figure><audio controls preload=\"metadata\" src=\"\(href)\"></audio>" + caption
    }
    return "<div class=\"attachment\">📎 <a href=\"\(href)\">\(label)</a></div>"
  }

  static func escape(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.utf8.count)
    for character in text {
      switch character {
      case "&": out.append("&amp;")
      case "<": out.append("&lt;")
      case ">": out.append("&gt;")
      case "\"": out.append("&quot;")
      default: out.append(character)
      }
    }
    return out
  }

  static func escapeAttribute(_ text: String) -> String {
    escape(text).replacingOccurrences(of: "'", with: "&#39;")
  }

  static let stylesheet = """
    :root{color-scheme:light dark;--me:#1f8cff;--them:#e9e9eb;--them-text:#111;--muted:#8a8a8e}
    body{margin:0;font:15px/1.4 -apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,sans-serif;\
    background:Canvas;color:CanvasText}
    header,main,footer{max-width:760px;margin:0 auto;padding:16px}
    header h1{margin:0 0 4px;font-size:22px}
    .meta,.participants,footer{color:var(--muted);font-size:13px}
    .participants{padding-left:18px;margin:8px 0 0}
    .day{text-align:center;font-size:12px;color:var(--muted);margin:24px 0 8px;font-weight:600}
    .row{display:flex;margin:6px 0}
    .row.me{justify-content:flex-end}
    .bubble{max-width:72%;padding:8px 12px;border-radius:18px;background:var(--them);\
    color:var(--them-text);word-wrap:break-word;overflow-wrap:anywhere}
    .row.me .bubble{background:var(--me);color:#fff}
    .who{font-size:12px;opacity:.8;margin-bottom:2px}
    .who time{opacity:.75;margin-left:6px}
    .bubble p{margin:0;white-space:pre-wrap}
    .subject{font-weight:600}
    .muted{font-style:italic;opacity:.8}
    .event{text-align:center;font-size:12px;color:var(--muted);margin:10px 0}
    .event time{margin-right:6px}
    .balloon .app{font-weight:600}
    .balloon a{color:inherit}
    figure{margin:6px 0 0}
    figure img,figure video{max-width:100%;border-radius:12px;display:block}
    figcaption{font-size:11px;opacity:.75;margin-top:2px}
    .attachment{margin-top:4px;font-size:13px}
    .attachment a{color:inherit}
    .edits{font-size:12px;margin-top:4px;opacity:.85}
    .edits ul{margin:4px 0 0;padding-left:16px}
    .error{font-size:12px;color:#ff453a;margin-top:4px}
    @media (prefers-color-scheme:dark){:root{--them:#26262a;--them-text:#f2f2f2}}
    @media print{.bubble{max-width:100%;border:1px solid #ccc}\
    .row.me .bubble{background:#dceeff;color:#000}}
    """
}
