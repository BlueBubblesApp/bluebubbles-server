//  RequestValues
//  Reading a request's inputs once, the same way everywhere.
//
//  Reaching into the parsed body by hand (`body["key"]?.stringValue` plus a hand-written
//  guard per required field) leaves every call site re-deciding what to throw and what to
//  say, and every new handler copying whichever neighbour it sits next to. These accessors
//  are the one place that decision is made.
//
//  **These accessors are lenient on purpose, and that is the reason this is not `Codable`.**
//  The obvious move is a decodable struct per request, and it would be wrong here: `Codable`
//  is strict about types, and this is a v1 surface shipped clients have been talking to for
//  years. A client sending `{"limit": "100"}` (a number as a string, which real clients do)
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
    // Path parameters arrive percent-encoded. An address with a `+` or an `@` in it
    // (which is most of them) is otherwise looked up in its encoded form and never found.
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
    // Finite only. `Double.init` accepts `inf`, `-inf` and `nan`, and every one of those
    // reaches arithmetic somewhere: `Int(inf * 100)` traps, and a `nan` bound silently
    // compares false against everything. A caller that wants to reject rather than ignore
    // should use one of the validating accessors below.
    guard let parsed = queryParameters[name].flatMap(Double.init), parsed.isFinite else {
      return nil
    }
    return parsed
  }

  // MARK: Validating accessors
  //
  // The lenient accessors above are the right default for v1: the reference mostly coerces
  // rather than rejects, and turning a coercion into a 400 is a wire change. These are for
  // the parameters the reference DOES validate (its `validators/` directory), and for
  // anything new, where matching that validation is what keeps a bad value from reaching
  // arithmetic that traps.
  //
  // Each one rejects with the reference's own status and wording where there is one.

  /// A query parameter constrained to a named set, rejected with a 400 when it is not.
  ///
  /// Absent stays absent: none of the reference's `in:` rules are also `required`, so an
  /// omitted parameter is the route's default rather than an error.
  func enumeration<Value: RawRepresentable>(
    _ name: String,
    as type: Value.Type,
    rejection: String
  ) throws -> Value? where Value.RawValue == String {
    guard let raw = queryParameters[name], !raw.isEmpty else { return nil }
    guard let value = Value(rawValue: raw) else { throw BadRequest(rejection) }
    return value
  }

  /// A query parameter that must be a whole number of at least one when it is present.
  ///
  /// The reference spells this `numeric|min:1`, and it means both halves: a non-numeric
  /// value is a 400 rather than a silent default, because a client sending `width=wide`
  /// has a bug it should be told about rather than an image served at the wrong size.
  func positiveInteger(_ name: String) throws -> Int? {
    guard let raw = queryParameters[name], !raw.isEmpty else { return nil }
    guard let value = Int(raw) else {
      throw BadRequest("The \(name) must be a number.")
    }
    guard value >= 1 else {
      throw BadRequest("The \(name) must be at least 1.")
    }
    return value
  }

  /// A boolean query parameter, matching `isTruthyBool` in the reference.
  ///
  /// Clients spell these several ways and have for years: `?original=1`, `?original=true`,
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
  /// Substring rather than equality: clients spell the same relation several ways
  /// (`chat`, `chats`, `chat.participants`) and the reference accepts all of them.
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
  /// (`RequestValuesTests` holds that line). On for a multipart form, which has no types
  /// (`partIndex` arrives as `"0"` and `isAudioMessage` as `"true"`) and whose values the
  /// reference coerces with `isTruthyBool` and `parseInt`.
  private let coercingStrings: Bool

  init(_ json: JSONValue, coercingStrings: Bool = false) {
    self.json = json
    self.coercingStrings = coercingStrings
  }

  /// The whole document, for the routes that hand the body onward rather than reading fields
  /// out of it: a contact to create, a backup to store, a capability set to parse.
  var raw: JSONValue { json }

  /// One raw field, for the handful whose shape is genuinely irregular.
  subscript(key: String) -> JSONValue? { json[key] }

  // MARK: - Optional reads
  //
  // `alias` covers the fields the reference accepts under two spellings: `totalChunks` and
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
  /// context than the key name: "`chatGuid` is required on the final chunk" is the reference's
  /// own wording and clients have seen it.
  func requireString(
    _ key: String, or alias: String? = nil, message: String? = nil
  ) throws -> String {
    guard let value = string(key, or: alias), !value.isEmpty else {
      throw BadRequest(message ?? Self.missing(key))
    }
    return value
  }

  /// A whole number, refused when it is present and cannot be delivered faithfully.
  ///
  /// **The one place this server is deliberately stricter than the reference.** The
  /// reference's rule is `numeric|min:0`, which `9223372036854775807` satisfies, and it then
  /// passes the value on. Here that number reaches the helper as the `Double` the wire
  /// carries, `WireJSON.intValue` answers nil rather than trapping (the fix that stopped it
  /// crashing the user's Messages), `RequestData.integer` falls back to its default, and the
  /// reaction is placed on part 0 — accepted, answered 200, and applied to the wrong part.
  ///
  /// "Apply it or refuse it" is the rule that governs, so this refuses. The test is not a
  /// magnitude but a round trip: a part index has to survive the JSON number it travels as,
  /// which is every integer up to 2^53 and no more. Nothing real is anywhere near that;
  /// a message has parts numbered in single digits.
  ///
  /// An ABSENT value is still nil, so a caller's own default applies (part 0, for every
  /// site that reads `partIndex`). Only a present-and-undeliverable one is a 400.
  ///
  /// The KEY is always passed, never defaulted, so the parameter's name stays visible at the
  /// call site: `RequestParameterParityTests` scopes its scan to the handler file that
  /// serves a route and asks whether the parameter is named there, and an accessor that hid
  /// the name behind a default argument would turn that check into a silent pass.
  func wholeNumber(_ key: String) throws -> Int? {
    guard let raw = json[key], !raw.isNull else { return nil }
    guard let value = int(key), Int(exactly: Double(value)) == value else {
      throw BadRequest(
        "`\(key)` must be a whole number this server can carry"
      )
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
  /// The recorded corpus shows the format: `GET /message/count/updated` without `after`
  /// answers "The after field is required." Most of the reference's required-field refusals
  /// come from a `required` rule in `validators/*.ts` and are generated in exactly this
  /// format; the handful that are hand-written pass `message:` instead.
  /// Internal rather than private: a handler that does its own presence check (the send
  /// routes, whose emptiness rule depends on the backend) has to produce the same sentence,
  /// and two spellings of a refusal a client may match on is how they drift apart.
  static func missing(_ key: String) -> String { "The \(key) field is required." }
}
