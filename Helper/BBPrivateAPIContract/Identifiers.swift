//  BBPrivateAPIContract: Identifiers
//  The two opaque identifiers every other type in this module is keyed by.
//
//  Both are `RawRepresentable` wrappers over `String` rather than bare strings, and that is
//  load-bearing rather than decorative: a chat identifier and a message GUID are both
//  strings of similar shape, and the compiler is the only thing that stops one being passed
//  where the other is wanted. They are in their own file because everything else here
//  depends on them and nothing here depends on anything else.

import Foundation

public struct ChatIdentifier: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible
{
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public var description: String { rawValue }

  /// Group chats use the `;+;` infix; direct messages use `;-;`.
  public var isGroup: Bool { rawValue.contains(";+;") }

  /// Whether this is shaped like a chat GUID at all: `<service>;<-|+>;<address>`.
  ///
  /// Not a validation of the service or the address, either of which this side has no
  /// business judging (macOS 26 writes the service as `any`, and an address can be a phone
  /// number, an email or a `chat…` room name). It answers one question: could Messages
  /// possibly have a chat under this string?
  ///
  /// It exists because the answer "no" has a specific, common cause worth naming. A
  /// semicolon is a metacharacter in more than one place a GUID travels through — `curl -F`
  /// reads it as the start of a field option and sends only `any` — so a truncated GUID
  /// arrives here as a plausible-looking string that can never match, and the failure reads
  /// as "the chat is missing" rather than "the request was mangled in transit".
  public var isWellFormed: Bool { isGroup || rawValue.contains(";-;") }
}

public struct MessageGUID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public var description: String { rawValue }
}
