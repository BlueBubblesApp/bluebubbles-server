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

  /// A query parameter as an integer, or nil when absent or unparsable.
  ///
  /// Lenient by the same rule as the body accessors: a client sending a limit that is not a
  /// number gets the route's default rather than a rejection.
  func integer(_ name: String) -> Int? {
    queryParameters[name].flatMap(Int.init)
  }
}

/// A parsed request body with typed, lenient reads and one consistent required-field failure.
struct RequestValues {

  private let json: JSONValue

  init(_ json: JSONValue) { self.json = json }

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
    json[key]?.intValue ?? alias.flatMap { json[$0]?.intValue }
  }

  func bool(_ key: String, or alias: String? = nil) -> Bool? {
    json[key]?.boolValue ?? alias.flatMap { json[$0]?.boolValue }
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

  /// The sentence 18 of the 24 hand-written guards already used, now used by all of them.
  /// Keeping the exact wording is not a preference — it is what clients have been shown.
  private static func missing(_ key: String) -> String { "`\(key)` is required" }
}
