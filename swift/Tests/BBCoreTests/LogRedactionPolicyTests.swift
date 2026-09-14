//  LogRedactionPolicyTests
//  An address in log metadata goes through `Redaction`; message content never goes in at all.
//
//  A log line is the artefact a person pastes into a public issue, and a raw phone number
//  or email in one is a leak the compiler cannot see: `.string(address)` type-checks whether
//  or not the value is a person's number. So the source tree is scanned, in the same shape
//  as `SettingKeyLiteralTests` and `TestDataPolicyTests`, and a hit fails the build.
//
//  Two rules, both keyed on the METADATA KEY, because the key is the one thing a log line
//  says about what its value is:
//
//    1. A key that names an address, a handle or a chat must wrap its value in
//       `Redaction.address`, `Redaction.chatGUID` or `Redaction.url`.
//    2. A key that names message content, a display name, a credential or a payload is
//       never a log key. There is no redacted form of a message body worth writing down.
//
//  Only the lines INSIDE a `logger.<level>(…)` call are examined, found by balancing the
//  call's parentheses: the same `"address": .string(x)` shape is also how a response and an
//  alert are built, and those are the wire and the notification, governed elsewhere. Within
//  a call the check is line-based, like its siblings: the key and its `.string(` are on one
//  line in every call site the formatter produces.
//
//  Three things about the matching, each of which was a hole this scan used to have.
//
//  **The exemption is per VALUE, not per line.** Asking whether the line mentions
//  `Redaction.` passes a line whose first key is redacted and whose second is not, and a
//  `logger.debug` with two or three metadata pairs on one line is the common shape. So each
//  key's own argument is extracted by balancing its parentheses and checked on its own.
//
//  **A key is matched by its WORDS, not by its exact spelling.** `"address"` was listed and
//  `"fromAddress"` was not, which is a distinction no reader would think the rule drew. The
//  key is split on camel case and underscores and each word is looked up. Two suffix
//  families then buy a key back out, because they say the value is a FACT about the thing
//  rather than the thing: an aggregate suffix (`count`, `index`, `duration`, …) exempts from
//  both rules, and an identifier suffix (`guid`, `id`, `uuid`) exempts from the content rule
//  only. That last split is the whole point of `messageGuid` being free and `chatGuid` not:
//  a message's GUID is not its text, but a chat's GUID names the people in it.
//
//  **`name` is matched by an explicit list**, not as a word: `eventName`, `serviceName` and
//  `roomName` are not people, and CLAUDE.md names event and room names as free to log.
//
//  Both tests assert a floor on how many log calls the walk found. Without it a scan that
//  silently stopped matching `logger.` at all — a rename, a moved tree, a regex typo — is
//  indistinguishable from a clean tree, and it passes.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import Foundation
import Testing

@Suite("Log metadata redaction policy")
struct LogRedactionPolicyTests {

  /// A word that names a person, or a place a person is reached.
  private static let addressWords: Set<String> = [
    "address", "addresses", "handle", "handles", "chat", "chats", "participant",
    "participants", "alias", "aliases", "email", "emails", "phone", "phones", "recipient",
    "recipients", "sender", "senders", "url", "urls",
  ]

  /// A word whose value has no acceptable redacted form.
  private static let contentWords: Set<String> = [
    "text", "message", "messages", "subject", "subjects", "body", "payload", "payloads",
    "password", "token", "tokens", "secret", "secrets", "credential", "credentials",
    "arguments", "data", "content",
  ]

  /// Keys that name a PERSON's name. `name` alone is far too broad to match as a word.
  private static let nameKeys: Set<String> = [
    "name", "displayname", "contactname", "sendername", "participantname", "groupname",
    "chatname", "filename", "fullname", "firstname", "lastname", "nickname", "username",
  ]

  /// A suffix saying the value is an aggregate ABOUT the thing: `chatCount` is a number.
  private static let aggregateSuffixes: Set<String> = [
    "count", "counts", "index", "length", "size", "bytes", "duration", "ms", "seconds",
    "type", "kind", "state", "status", "code", "reason", "total", "limit", "offset",
    "version", "port", "enabled", "mode", "level", "elapsed", "attempt", "attempts",
  ]

  /// A suffix naming an identifier. Exempts from the content rule only: a message's GUID is
  /// not its text, but a chat's GUID still names the people in the chat.
  private static let identifierSuffixes: Set<String> = [
    "guid", "guids", "id", "ids", "uuid", "uuids", "rowid", "rowids", "identifier",
    "identifiers",
  ]

  @Test("An address-shaped log key wraps its value in Redaction")
  func addressKeysAreRedacted() throws {
    var offenders: [String] = []
    let calls = try Self.forEachLogMetadata { label, index, key, value, code in
      guard Self.namesAnAddress(key) else { return }
      guard !value.contains("Redaction.") else { return }
      offenders.append("\(label):\(index): \"\(key)\" in: \(code)")
    }
    #expect(calls > 200, "the scan found too few log calls to mean anything")
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "log metadata carrying an address without `Redaction`:\n"
          + offenders.joined(separator: "\n"))
    )
  }

  @Test("Message content, credentials and payloads are never log keys")
  func contentKeysNeverLogged() throws {
    var offenders: [String] = []
    let calls = try Self.forEachLogMetadata { label, index, key, _, code in
      guard Self.namesContent(key) else { return }
      offenders.append("\(label):\(index): \"\(key)\" in: \(code)")
    }
    #expect(calls > 200, "the scan found too few log calls to mean anything")
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "log metadata carrying content that has no redacted form:\n"
          + offenders.joined(separator: "\n"))
    )
  }

  @Test("The key classifier draws the lines the header claims it draws")
  func classifierIsCalibrated() {
    for key in ["address", "fromAddress", "senderHandle", "chatGuid", "chatGUID", "toURL"] {
      #expect(Self.namesAnAddress(key), "\(key) should need redaction")
    }
    for key in ["chatCount", "handleIndex", "messageGuid", "eventName", "roomName"] {
      #expect(!Self.namesAnAddress(key), "\(key) should not need redaction")
    }
    for key in ["text", "messageText", "pushToken", "displayName", "fileName", "requestBody"] {
      #expect(Self.namesContent(key), "\(key) should be refused outright")
    }
    for key in ["messageGuid", "messageCount", "tokenCount", "serviceName", "metadata"] {
      #expect(!Self.namesContent(key), "\(key) should be allowed")
    }
  }

  // MARK: - Classifying a key

  private static func namesAnAddress(_ key: String) -> Bool {
    let words = Self.words(of: key)
    guard let last = words.last, !Self.aggregateSuffixes.contains(last) else { return false }
    return words.contains { Self.addressWords.contains($0) }
  }

  private static func namesContent(_ key: String) -> Bool {
    let words = Self.words(of: key)
    if Self.nameKeys.contains(words.joined()) { return true }
    guard let last = words.last else { return false }
    if Self.aggregateSuffixes.contains(last) || Self.identifierSuffixes.contains(last) {
      return false
    }
    return words.contains { Self.contentWords.contains($0) }
  }

  /// Splits `fromAddress`, `chatGUID` and `chat_guid` alike into lowercased words.
  private static func words(of key: String) -> [String] {
    var words: [String] = []
    var current = ""
    let characters = Array(key)
    for (offset, character) in characters.enumerated() {
      guard character.isLetter || character.isNumber else {
        if !current.isEmpty { words.append(current.lowercased()) }
        current = ""
        continue
      }
      let nextIsLower = offset + 1 < characters.count && characters[offset + 1].isLowercase
      let previousIsLower = offset > 0 && characters[offset - 1].isLowercase
      // A boundary is a lower-to-upper step, or the last capital of an acronym run.
      if character.isUppercase, !current.isEmpty, previousIsLower || nextIsLower {
        words.append(current.lowercased())
        current = ""
      }
      current.append(character)
    }
    if !current.isEmpty { words.append(current.lowercased()) }
    return words
  }

  // MARK: - Scanning

  /// Visits every `"key": .case(…)` pair inside a `logger.<level>(` call, with the pair's own
  /// argument text, and returns how many calls were seen.
  @discardableResult
  private static func forEachLogMetadata(
    _ visit: (_ label: String, _ line: Int, _ key: String, _ value: String, _ code: String) ->
      Void
  ) throws -> Int {
    // Built per call: `Regex` is not Sendable, so it cannot be a static.
    let logCall = try Regex(#"logger\.(?:trace|debug|info|notice|warning|error|critical|log)\("#)
    let pair = try Regex(#""([A-Za-z][A-Za-z0-9_]*)"\s*:\s*\.[A-Za-z][A-Za-z0-9]*\("#)
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    var calls = 0
    for directory in ["Sources", "Helper"] {
      let base = root.appending(path: directory)
      guard let files = FileManager.default.enumerator(atPath: base.path) else { continue }
      for case let relative as String in files where relative.hasSuffix(".swift") {
        let label = directory + "/" + relative
        let source = try String(contentsOf: base.appending(path: relative), encoding: .utf8)
        var depth = 0
        for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
          .enumerated()
        {
          let code = line.trimmingCharacters(in: .whitespaces)
          if code.hasPrefix("//") { continue }
          var tail = Substring(code)
          if depth == 0 {
            guard let match = code.firstMatch(of: logCall) else { continue }
            calls += 1
            // Depth starts at one for the call's own opening parenthesis.
            depth = 1
            tail = code[match.range.upperBound...]
          }
          for match in code.matches(of: pair) {
            guard let key = match.output[1].substring else { continue }
            visit(
              label, index + 1, String(key),
              String(Self.argument(of: code, openingAt: match.range.upperBound)), code)
          }
          for character in tail {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
          }
          if depth < 0 { depth = 0 }
        }
      }
    }
    return calls
  }

  /// The text between a `.case(` already consumed and its matching `)`, or the rest of the
  /// line when the argument spills onto the next one.
  private static func argument(of code: String, openingAt start: String.Index) -> Substring {
    var depth = 1
    var index = start
    while index < code.endIndex {
      if code[index] == "(" { depth += 1 }
      if code[index] == ")" {
        depth -= 1
        if depth == 0 { return code[start..<index] }
      }
      index = code.index(after: index)
    }
    return code[start...]
  }
}
