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
//  **The injected helpers are a third rule, because they log differently.** `Helper/` does
//  not link `BBCore`, so it has no `Redaction` and no metadata: each helper line is one
//  string, logged `.public` through `HelperLog` (see its header for why). So nothing the
//  server can redact may reach one at all: every `\(…)` interpolated into a helper log call
//  is tokenised, and an identifier naming an address, content, a person's name or a FILE
//  PATH fails the build. Paths are on this list and not the server's because the helper's
//  paths are inside the user's home directory (an attachment's persistent copy, the socket in
//  Messages' container), and so name the person. A forwarder such as `{ log.info($0) }`
//  interpolates nothing and passes, which is right: what it forwards is itself a log call in
//  the scanned tree.
//
//  All three tests assert a floor on how many log calls the walk found. Without it a scan
//  that silently stopped matching at all — a rename, a moved tree, a regex typo — is
//  indistinguishable from a clean tree, and it passes.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBTestSupport
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

  /// A word naming a place on disk. Refused in the helpers only; see the header.
  private static let pathWords: Set<String> = [
    "path", "paths", "file", "files", "directory", "directories", "folder", "folders",
    "home", "location", "locations",
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

  @Test("A helper log line interpolates no address, content or file path")
  func helperLinesCarryNothingPersonal() throws {
    var offenders: [String] = []
    let calls = try Self.forEachHelperLogInterpolation { label, line, identifier, code in
      guard
        Self.namesAnAddress(identifier) || Self.namesContent(identifier)
          || Self.namesAPath(identifier)
      else { return }
      offenders.append("\(label):\(line): `\(identifier)` in: \(code)")
    }
    #expect(calls > 15, "the scan found \(calls) helper log calls, which cannot be right")
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a helper log line interpolating something that names a person or a path "
          + "(log a count, a kind or a domain and code instead):\n"
          + offenders.joined(separator: "\n"))
    )
  }

  /// Where an error's description is somebody else's prose: a helper's refusal, an
  /// AppleScript error, a FaceTime bridge's. Those name the address or chat they could not
  /// find ("no iMessage handle for …"), which is right in the reply to the client that sent
  /// it and wrong in a log. The key is `error`, which names nothing, so the rules above
  /// cannot see it; these files wrap it in `Redaction.identifiers(in:)` instead.
  private static let foreignProse: [String] = [
    "Sources/BBPrivateAPI/", "Sources/BBAppleScript/", "Sources/BBFaceTime/",
    "Sources/BBInterfaces/MessagesBackedInterface.swift",
    "Sources/BBInterfaces/FaceTimeInterface.swift",
    "Sources/BBInterfaces/ApplicationRestartCoordinator.swift",
  ]

  @Test("An error from Messages or a helper is logged through Redaction")
  func foreignErrorsAreRedacted() throws {
    var offenders: [String] = []
    _ = try Self.forEachLogMetadata { label, index, key, value, code in
      guard ["error", "reason", "detail"].contains(key),
        Self.foreignProse.contains(where: label.hasPrefix), !value.contains("Redaction.")
      else { return }
      offenders.append("\(label):\(index): \"\(key)\" in: \(code)")
    }
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "an error description that can quote an address, logged as it is "
          + "(wrap it in `Redaction.identifiers(in:)`):\n" + offenders.joined(separator: "\n"))
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
    for key in ["path", "socketPath", "localPath", "persistentPath", "fileURL", "homeDirectory"] {
      #expect(Self.namesAPath(key), "\(key) should be refused in a helper line")
    }
    for key in ["pathBytes", "fileCount", "capacity", "selector", "error"] {
      #expect(!Self.namesAPath(key), "\(key) should be allowed in a helper line")
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

  private static func namesAPath(_ key: String) -> Bool {
    let words = Self.words(of: key)
    guard let last = words.last, !Self.aggregateSuffixes.contains(last) else { return false }
    return words.contains { Self.pathWords.contains($0) }
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
    var calls = 0
    for file in try SourceScanner.swiftFiles(under: "Sources", "Helper") {
      var depth = 0
      for line in file.codeLines {
        let code = line.code.trimmingCharacters(in: .whitespaces)
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
            file.path, line.number, String(key),
            String(Self.argument(of: code, openingAt: match.range.upperBound)), code)
        }
        for character in tail {
          if character == "(" { depth += 1 }
          if character == ")" { depth -= 1 }
        }
        if depth < 0 { depth = 0 }
      }
    }
    return calls
  }

  /// Visits every identifier inside a `\(…)` interpolated into a helper log call: `log(…)` in
  /// the socket client and `log.info(…)` / `log.error(…)` everywhere else. Returns how many
  /// calls were seen. `HelperLog.swift` is the implementation, not a caller, and is skipped.
  @discardableResult
  private static func forEachHelperLogInterpolation(
    _ visit: (_ label: String, _ line: Int, _ identifier: String, _ code: String) -> Void
  ) throws -> Int {
    // SIMPLE word boundaries: the default (Unicode) ones treat `BlueBubblesHelper.log` as
    // one word, so `\b` never matched the commonest spelling of the call.
    let logCall = try Regex(#"\blog(?:\.(?:info|error))?\("#).wordBoundaryKind(.simple)
    let stringLiteral = try Regex(#""[^"]*""#)
    let identifier = try Regex(#"[A-Za-z_][A-Za-z0-9_]*"#)
    var calls = 0
    for file in try SourceScanner.swiftFiles(under: "Helper")
    where !file.path.hasSuffix("HelperLog.swift") {
      var depth = 0
      for line in file.codeLines {
        let code = line.code.trimmingCharacters(in: .whitespaces)
        var tail = Substring(code)
        if depth == 0 {
          guard let match = code.firstMatch(of: logCall) else { continue }
          calls += 1
          depth = 1
          tail = code[match.range.upperBound...]
        }
        var search = tail.startIndex
        while let open = tail[search...].range(of: "\\(") {
          let expression = Self.argument(of: code, openingAt: open.upperBound)
          let bare = String(expression).replacing(stringLiteral, with: "")
          for token in bare.matches(of: identifier) {
            visit(file.path, line.number, String(bare[token.range]), code)
          }
          search = open.upperBound
        }
        for character in tail {
          if character == "(" { depth += 1 }
          if character == ")" { depth -= 1 }
        }
        if depth < 0 { depth = 0 }
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
