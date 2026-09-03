//  RequestValues
//  Reading a request's inputs once, the same way everywhere.
//
//  Reaching into the parsed body by hand — `body["key"]?.stringValue` plus a hand-written
//  guard per required field — leaves every call site re-deciding what to throw and what to
//  say, and every new handler copying whichever neighbour it sits next to. These accessors
//  are the one place that decision is made.
//
//  **These accessors are lenient on purpose, and that is the reason this is not `Codable`.**
//  The obvious move is a decodable struct per request, and it would be wrong here: `Codable`
//  is strict about types, and this is a v1 surface shipped clients have been talking to for
//  years. A client sending `{"limit": "100"}` — a number as a string, which real clients do —
//  currently falls back to the default; under `Codable` it would throw, and a request that has
//  worked for years would start failing. Leniency is the compatibility contract, so the
//  accessors preserve it and only the REQUIRED checks are standardised.
//
//  See `.claude/docs/api.md`.

import BBHTTPAPI
import BBInterfaces
import BBSerialization
import Foundation

extension APIRequestContext {

  /// The request body, parsed once, ready to be read field by field.
  ///
  /// An absent or empty body is an empty object rather than an error: many routes take an
  /// entirely optional body, and the required-field checks below are what decide whether that
  /// is acceptable for any given one.
  func values() throws -> RequestValues {
    RequestValues(try jsonBody() ?? .object([:]))
  }

  func requirePathParameter(_ name: String) throws -> String {
    guard let value = pathParameters[name], !value.isEmpty else {
      throw BadRequest("missing path parameter `\(name)`")
    }
    // Path parameters arrive percent-encoded. An address with a `+` or an `@` in it —
    // which is most of them — is otherwise looked up in its encoded form and never found.
    return value.removingPercentEncoding ?? value
  }

  func requireQueryParameter(_ name: String) throws -> String {
    guard let value = queryParameters[name], !value.isEmpty else {
      throw BadRequest("missing query parameter `\(name)`")
    }
    return value
  }

  /// The `:id` path parameter as a number.
  func identifier() throws -> Int64 {
    let raw = try requirePathParameter("id")
    guard let id = Int64(raw) else { throw BadRequest("`id` must be a number") }
    return id
  }

  // MARK: Query parameters
  //
  // Every one of these was being written slightly differently at each call site, and "did
  // this route accept `chatGuid` or `chat_guid`" is exactly the kind of drift the parity
  // harness cannot see. This is the one place.

  /// A query parameter as an integer, or nil when absent or unparsable.
  ///
  /// Lenient by the same rule as the body accessors: a client sending a limit that is not a
  /// number gets the route's default rather than a rejection.
  func integer(_ name: String) -> Int? {
    queryParameters[name].flatMap(Int.init)
  }
  /// A query parameter as a date. Epoch MILLISECONDS, matching the wire format.
  func date(_ name: String) -> Date? {
    guard let raw = queryParameters[name], let milliseconds = Double(raw) else { return nil }
    return Date(timeIntervalSince1970: milliseconds / 1000)
  }

  func has(_ name: String) -> Bool {
    queryParameters[name] != nil
  }

  func decimal(_ name: String) -> Double? {
    queryParameters[name].flatMap(Double.init)
  }

  /// A boolean query parameter, matching `isTruthyBool` in the current server.
  ///
  /// Clients spell these several ways and have for years — `?original=1`, `?original=true`,
  /// and a bare `?original` with no value. Accepting only `"true"` would silently ignore
  /// two of the three and serve a converted file to a caller who asked for the original.
  func truthy(_ name: String) -> Bool {
    guard let raw = queryParameters[name] else { return false }
    // Present but empty is `?original`, which is an assertion, not an absence.
    if raw.isEmpty { return true }
    return ["1", "true", "yes"].contains(raw.lowercased())
  }

  /// Whether the `with` parameter asks for a relation.
  ///
  /// Substring rather than equality: clients spell the same relation several ways —
  /// `chat`, `chats`, `chat.participants` — and the current server accepts all of them.
  func wants(_ relation: String) -> Bool {
    guard let raw = queryParameters["with"] else { return false }
    return raw.lowercased()
      .split(separator: ",")
      .contains { $0.trimmingCharacters(in: .whitespaces).contains(relation) }
  }
}

/// A parsed request body with typed, lenient reads and one consistent required-field failure.
struct RequestValues {

  private let json: JSONValue
  /// Whether a numeric or boolean read accepts a STRING holding one.
  ///
  /// Off for JSON, where a wrong-typed field reads as absent so the route's default applies
  /// (`RequestValuesTests` holds that line). On for a multipart form, which has no types —
  /// `partIndex` arrives as `"0"` and `isAudioMessage` as `"true"` — and whose values the
  /// reference coerces with `isTruthyBool` and `parseInt`.
  private let coercingStrings: Bool

  init(_ json: JSONValue, coercingStrings: Bool = false) {
    self.json = json
    self.coercingStrings = coercingStrings
  }

  /// The whole document, for the routes that hand the body onward rather than reading fields
  /// out of it — a contact to create, a backup to store, a capability set to parse.
  var raw: JSONValue { json }

  /// One raw field, for the handful whose shape is genuinely irregular.
  subscript(key: String) -> JSONValue? { json[key] }

  // MARK: - Optional reads
  //
  // `alias` covers the fields the reference accepts under two spellings — `totalChunks` and
  // `total`, `filePath` and `path`. Both are in the wild, so both keep working.

  func string(_ key: String, or alias: String? = nil) -> String? {
    json[key]?.stringValue ?? alias.flatMap { json[$0]?.stringValue }
  }

  func int(_ key: String, or alias: String? = nil) -> Int? {
    integer(json[key]) ?? alias.flatMap { integer(json[$0]) }
  }

  func bool(_ key: String, or alias: String? = nil) -> Bool? {
    boolean(json[key]) ?? alias.flatMap { boolean(json[$0]) }
  }

  func double(_ key: String, or alias: String? = nil) -> Double? {
    decimal(json[key]) ?? alias.flatMap { decimal(json[$0]) }
  }

  private func integer(_ value: JSONValue?) -> Int? {
    switch value {
    case .int, .int64: value?.intValue
    case .string(let text)? where coercingStrings:
      Int(text.trimmingCharacters(in: .whitespaces))
    default: nil
    }
  }

  private func decimal(_ value: JSONValue?) -> Double? {
    switch value {
    case .double(let number)?: number
    case .int(let number)?: Double(number)
    case .int64(let number)?: Double(number)
    case .string(let text)? where coercingStrings:
      Double(text.trimmingCharacters(in: .whitespaces))
    default: nil
    }
  }

  /// A form boolean follows `isTruthyBool`: `"1"`, `"true"` and `"yes"` are true and
  /// anything else is false.
  private func boolean(_ value: JSONValue?) -> Bool? {
    switch value {
    case .bool(let flag)?: flag
    case .string(let text)? where coercingStrings:
      ["1", "true", "yes"].contains(text.lowercased())
    default: nil
    }
  }

  func array(_ key: String, or alias: String? = nil) -> [JSONValue]? {
    json[key]?.arrayValue ?? alias.flatMap { json[$0]?.arrayValue }
  }

  // MARK: - Required reads

  /// A required string, rejected when absent OR empty.
  ///
  /// Empty counts as missing: an empty GUID reaches the database as a lookup that cannot
  /// match rather than as a request anybody meant to send.
  ///
  /// `message` overrides the standard sentence for the three fields whose refusal needs more
  /// context than the key name — "`chatGuid` is required on the final chunk" is the reference's
  /// own wording and clients have seen it.
  func requireString(
    _ key: String, or alias: String? = nil, message: String? = nil
  ) throws -> String {
    guard let value = string(key, or: alias), !value.isEmpty else {
      throw BadRequest(message ?? Self.missing(key))
    }
    return value
  }

  func requireInt(_ key: String, or alias: String? = nil, message: String? = nil) throws -> Int {
    guard let value = int(key, or: alias) else { throw BadRequest(message ?? Self.missing(key)) }
    return value
  }

  func requireArray(
    _ key: String, or alias: String? = nil, message: String? = nil
  ) throws -> [JSONValue] {
    guard let value = array(key, or: alias) else {
      throw BadRequest(message ?? Self.missing(key))
    }
    return value
  }

  /// validatorjs's own sentence for a `required` rule, which is what the reference sends.
  ///
  /// This read "`\(key)` is required" and was described here as "what clients have been
  /// shown" — it was not. It was what 18 of this server's 24 hand-written guards happened to
  /// say, and the recorded corpus disagrees in the one place it can be seen:
  /// `GET /message/count/updated` without `after` answers "The after field is required."
  /// Most of the reference's required-field refusals come from a `required` rule in
  /// `validators/*.ts` and are generated in exactly this format; the handful that are
  /// hand-written pass `message:` instead.
  private static func missing(_ key: String) -> String { "The \(key) field is required." }
}
