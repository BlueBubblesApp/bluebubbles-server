//  ChatGUID
//  Parsing and normalising chat GUIDs across the macOS 26 service-prefix change.
//
//  The change
//  ----------
//  A chat GUID has always been `<service>;<separator>;<address>` — `iMessage;-;+12025550143`
//  for a direct chat, `iMessage;+;chat123456` for a group. The service prefix named the
//  service, and both clients and the server parse it that way.
//
//  **macOS 26 replaced the service prefix with the literal `any`**, and it did so as a
//  MIGRATION, not just for new rows. Verified against a live macOS 26.5.2 chat.db:
//
//      chat rows with an `any;` prefix ........ 479  (100%)
//      chat rows with a legacy prefix .......... 0
//      of those, chats holding pre-2023 messages 325
//
//  Historical rows were rewritten in place. There is no mixed state to handle on a migrated
//  database and no legacy GUID left to match against.
//
//  What that breaks
//  ----------------
//  1. **Every GUID a client cached is now stale.** A client asking for
//     `iMessage;-;someone@example.com` finds nothing, because the row now reads
//     `any;-;someone@example.com`. The chat is right there; the lookup misses.
//  2. **The service is no longer in the GUID.** It moved to `chat.service_name`, which still
//     carries `iMessage`/`SMS` correctly. Anything deriving a service from the GUID gets
//     `"any"` on macOS 26.
//
//  How this handles it
//  -------------------
//  GUIDs are compared on their **separator and address**, never on the service prefix. A
//  lookup for `iMessage;-;X`, `any;-;X` or `SMS;-;X` resolves to the same chat, which makes
//  old clients keep working on a migrated database and new ones keep working on an older one.
//  The service comes from `chat.service_name` when a caller needs it.
//
//  See `.claude/docs/api.md`.

import Foundation

/// The iMessage service a send should use.
public enum MessagingService: String, Sendable, CaseIterable {
  case iMessage
  case sms = "SMS"
  case rcs = "RCS"

  /// The `service type` enumerator, which is a bare AppleScript term rather than a string.
  public var appleScriptEnumerator: String {
    switch self {
    case .iMessage: "iMessage"
    case .sms: "SMS"
    case .rcs: "RCS"
    }
  }

  /// Parses the service half of a chat GUID (`iMessage;-;+1555…`), defaulting the way the
  /// current server does.
  public static func parse(_ raw: String?) -> MessagingService {
    guard let raw, !raw.isEmpty else { return .iMessage }
    return MessagingService.allCases.first {
      $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame
    } ?? .iMessage
  }
}

/// A parsed chat GUID.
public struct ChatGUID: Sendable, Equatable, CustomStringConvertible {

  /// The literal macOS 26 uses in place of a service name.
  public static let anyServicePrefix = "any"

  /// `-` for a direct chat, `+` for a group. Unchanged by the macOS 26 migration.
  public enum Separator: String, Sendable, Equatable {
    case direct = "-"
    case group = "+"
  }

  /// Exactly as it appeared in the input, which may be `any`.
  public let servicePrefix: String
  public let separator: Separator
  public let address: String

  public init(servicePrefix: String, separator: Separator, address: String) {
    self.servicePrefix = servicePrefix
    self.separator = separator
    self.address = address
  }

  /// Parses `service;sep;address`. Returns nil for anything not of that shape.
  public init?(_ raw: String) {
    let parts = raw.components(separatedBy: ";")
    guard parts.count >= 3,
      let separator = Separator(rawValue: parts[1])
    else { return nil }

    self.servicePrefix = parts[0]
    self.separator = separator
    // Re-joined: an address can itself contain a semicolon in principle, and splitting
    // it away would silently truncate.
    self.address = parts.dropFirst(2).joined(separator: ";")
  }

  public var description: String { "\(servicePrefix);\(separator.rawValue);\(address)" }

  public var isGroup: Bool { separator == .group }

  /// Whether the prefix is macOS 26's placeholder rather than a real service.
  public var hasAnyServicePrefix: Bool {
    servicePrefix.caseInsensitiveCompare(Self.anyServicePrefix) == .orderedSame
  }

  /// The service the prefix names, or nil when it names none.
  ///
  /// nil on macOS 26 is not a failure — it means "ask `chat.service_name`", which is where
  /// the information actually lives now.
  public var declaredService: MessagingService? {
    guard !hasAnyServicePrefix else { return nil }
    return MessagingService.allCases.first {
      $0.rawValue.caseInsensitiveCompare(servicePrefix) == .orderedSame
    }
  }

  /// The comparison key: separator and address, with the service prefix dropped.
  ///
  /// This is what makes `iMessage;-;X` and `any;-;X` the same chat.
  public var identityKey: String {
    "\(separator.rawValue);\(address.lowercased())"
  }

  /// The same chat, expressed with a different service prefix.
  public func with(servicePrefix: String) -> ChatGUID {
    ChatGUID(servicePrefix: servicePrefix, separator: separator, address: address)
  }

  /// Every prefix spelling worth trying when looking a chat up.
  ///
  /// Ordered so the caller's own spelling is tried first — on an unmigrated database that
  /// is the one that hits, and on a migrated one it costs a single extra comparison.
  public func lookupCandidates() -> [String] {
    var candidates = [description]
    for prefix in [Self.anyServicePrefix] + MessagingService.allCases.map(\.rawValue)
    where prefix.caseInsensitiveCompare(servicePrefix) != .orderedSame {
      candidates.append(with(servicePrefix: prefix).description)
    }
    return candidates
  }
}

extension ChatGUID {

  /// Whether two GUIDs name the same chat, ignoring the service prefix.
  public static func sameChat(_ lhs: String, _ rhs: String) -> Bool {
    guard let left = ChatGUID(lhs), let right = ChatGUID(rhs) else {
      return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
    return left.identityKey == right.identityKey
  }
}
