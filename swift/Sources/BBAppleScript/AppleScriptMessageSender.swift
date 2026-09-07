//  AppleScriptMessageSender
//  The send path that works with SIP enabled.
//
//  This is not a degraded mode. Most users will never disable SIP, so this is the
//  configuration the majority actually run, and it is proven before the Private API path is
//  built. See `.claude/docs/imessage.md`.

import BBCore
import BBDiagnostics
import Foundation
import Logging

public enum MessageSendError: BBError, Equatable, CustomStringConvertible {
  /// Neither text nor an attachment. The current server returns null here rather than
  /// scripting a no-op.
  case nothingToSend
  case invalidChatGUID(String)
  /// The one-to-one fallback cannot address a group.
  case cannotFallbackForGroupChat(String)
  case attachmentMissing(path: String)
  case automationNotPermitted
  case messagesNotRunning
  case scriptFailed(number: Int, message: String)
  /// No spelling of the GUID resolved to a chat Messages knows about.
  ///
  /// Distinct from `scriptFailed` on purpose. `lookupCandidates()` tries the GUID as given
  /// and then every other service prefix, so surfacing the last attempt's raw AppleScript
  /// error told the user their `iMessage;-;…` request had failed as `RCS;-;…` — which reads
  /// as the server having picked RCS rather than as "this chat does not exist".
  case chatNotFound(guid: String, attempted: [String])

  /// What the user is shown.
  ///
  /// Without this the HTTP layer renders the enum case — a real response was
  /// `scriptFailed(number: -1728, message: "Messages got an error: Can\u2019t get chat id
  /// \"RCS;-;…\"")`, which is a Swift value, an AppleScript error number and a misleading
  /// service prefix in one string, and tells the reader nothing they can act on.
  public var description: String {
    switch self {
    case .nothingToSend:
      "A message needs text or an attachment."
    case .invalidChatGUID(let guid):
      "\(guid) is not a valid chat identifier."
    case .cannotFallbackForGroupChat(let guid):
      "\(guid) is a group chat, and a group cannot be addressed by participant. "
        + "Send to the chat itself."
    case .attachmentMissing(let path):
      "No file exists at \(path)."
    case .automationNotPermitted:
      "This server is not allowed to control Messages. Grant it Automation access in "
        + "System Settings › Privacy & Security › Automation."
    case .messagesNotRunning:
      "Messages is not running."
    case .chatNotFound(let guid, let attempted):
      "Messages has no chat matching \(guid). Tried \(attempted.count) "
        + "identifier spelling\(attempted.count == 1 ? "" : "s"); the chat may not "
        + "exist yet, in which case send to the address instead."
    case .scriptFailed(let number, let message):
      // The AppleScript error number is kept: it is the one thing that makes an
      // unfamiliar failure searchable.
      "Messages refused the request (AppleScript error \(number)): \(message)"
    }
  }

  init(_ error: AppleScriptError) {
    switch error {
    case .notPermitted: self = .automationNotPermitted
    case .targetNotRunning: self = .messagesNotRunning
    case .executionFailed(let number, let message):
      self = .scriptFailed(number: number, message: message)
    case .compilationFailed(let message):
      self = .scriptFailed(number: 0, message: message)
    }
  }
}

/// Sends through Messages.app via compiled AppleScript.
public actor AppleScriptMessageSender {

  private let runner: any AppleScriptRunning
  private let formatter: AddressFormatter
  private let logger: Logger
  /// Resolved once: the local Messages dictionary decides whether the script can name RCS.
  private let scriptSource: String

  public init(
    runner: any AppleScriptRunning = AppleScriptRunner(),
    formatter: AddressFormatter = .shared,
    logger: Logger = Logger(label: "bluebubbles.applescript.send")
  ) {
    self.runner = runner
    self.formatter = formatter
    self.logger = logger
    self.scriptSource = MessagesScripts.source()
  }

  /// Sends to an existing chat.
  ///
  /// The GUID is normalised twice over: the address half into the form Messages stored, and
  /// the service prefix into whatever the local Messages accepts. On macOS 26 that prefix
  /// is `any`, and a client-supplied `iMessage;-;…` would otherwise miss — see ChatGUID.
  @discardableResult
  public func send(
    chatGUID rawGUID: String,
    text: String? = nil,
    attachmentPath: String? = nil
  ) async throws -> String {
    let message = text ?? ""
    let attachment = attachmentPath ?? ""
    guard !message.isEmpty || !attachment.isEmpty else { throw MessageSendError.nothingToSend }
    try validateAttachment(attachment)

    guard let parsed = ChatGUID(rawGUID) else {
      throw MessageSendError.invalidChatGUID(rawGUID)
    }
    let normalized = normalize(parsed)

    // Tried in order. On a macOS 26 database only the `any` spelling resolves; on an
    // older one only the service spelling does. Trying both means one build works on
    // every supported release, and the cost of a miss is one failed script call.
    // The LAST failure is kept only as a fallback; the error actually reported names the
    // GUID the caller asked for. Reporting the last candidate instead is actively
    // misleading: asking for `iMessage;-;someone` and being told `Can't get chat id
    // "RCS;-;someone"` reads as though the server chose RCS, when in fact every spelling
    // was tried and none matched. Cost a real debugging detour.
    var lastError: MessageSendError = .invalidChatGUID(rawGUID)
    var attempted: [String] = []
    for candidate in normalized.lookupCandidates() {
      attempted.append(candidate)
      do {
        _ = try await runner.run(
          key: MessagesScripts.cacheKey,
          source: scriptSource,
          handler: MessagesScripts.sendToChat,
          arguments: [.string(candidate), .string(message), .path(attachment)],
          target: "Messages"
        )
        return candidate
      } catch let error as AppleScriptError {
        let mapped = MessageSendError(error)
        // Permission and a missing Messages are terminal — retrying another spelling
        // of the GUID cannot help, and would just produce three identical prompts.
        switch mapped {
        case .automationNotPermitted, .messagesNotRunning: throw mapped
        default: lastError = mapped
        }
      }
    }

    // No spelling resolved, which almost always means the chat does not exist rather
    // than that the GUID was malformed — so say that, and say what was tried.
    if case .invalidChatGUID = lastError {
      throw lastError
    }
    throw MessageSendError.chatNotFound(guid: rawGUID, attempted: attempted)
  }

  /// Sends directly to an address, for a one-to-one chat that may not exist yet.
  @discardableResult
  public func send(
    address: String,
    service: MessagingService = .iMessage,
    text: String? = nil,
    attachmentPath: String? = nil
  ) async throws -> String {
    let message = text ?? ""
    let attachment = attachmentPath ?? ""
    guard !message.isEmpty || !attachment.isEmpty else { throw MessageSendError.nothingToSend }
    try validateAttachment(attachment)

    // Checked on the RAW address, before formatting. Slugifying strips everything that
    // is not a digit or `+`, so `chat000000000000000001` becomes a run of digits and the
    // prefix test silently stops matching — which sends a group identifier down the
    // one-to-one path and blocks in AppleScript instead of failing here.
    guard !address.lowercased().hasPrefix("chat") else {
      throw MessageSendError.cannotFallbackForGroupChat(address)
    }
    let formatted = formatter.iMessageFormat(address)

    do {
      _ = try await runner.run(
        key: MessagesScripts.cacheKey,
        source: scriptSource,
        handler: MessagesScripts.sendToParticipant,
        arguments: [
          .string(formatted), .string(service.rawValue),
          .string(message), .path(attachment),
        ],
        target: "Messages"
      )
      return formatted
    } catch let error as AppleScriptError {
      throw MessageSendError(error)
    }
  }

  /// Normalises the address half. Group identifiers are opaque and left alone.
  private func normalize(_ guid: ChatGUID) -> ChatGUID {
    guard !guid.isGroup else { return guid }
    return ChatGUID(
      servicePrefix: guid.servicePrefix,
      separator: guid.separator,
      address: formatter.iMessageFormat(guid.address)
    )
  }

  /// Checked here rather than in AppleScript: `as POSIX file` on a missing path fails with
  /// an opaque -43, which tells the user nothing about which file was missing.
  private func validateAttachment(_ path: String) throws {
    guard !path.isEmpty else { return }
    guard FileManager.default.fileExists(atPath: path) else {
      throw MessageSendError.attachmentMissing(path: path)
    }
  }
}

extension MessageSendError {
  public var code: String {
    switch self {
    case .nothingToSend: "applescript.nothing_to_send"
    case .invalidChatGUID: "applescript.invalid_chat_guid"
    case .cannotFallbackForGroupChat: "applescript.no_group_fallback"
    case .attachmentMissing: "applescript.attachment_missing"
    case .automationNotPermitted: "applescript.automation_not_permitted"
    case .messagesNotRunning: "applescript.messages_not_running"
    case .scriptFailed: "applescript.script_failed"
    case .chatNotFound: "applescript.chat_not_found"
    }
  }

  public var domain: String { "Messaging" }

  /// Only the two the user can fix. A malformed GUID is a client's mistake, and a failed
  /// send already reports itself to the client that asked for it.
  public var isUserFacing: Bool {
    switch self {
    case .automationNotPermitted, .messagesNotRunning: true
    default: false
    }
  }

  public var title: String { "Could not send the message" }

  public var body: String { description }
}
