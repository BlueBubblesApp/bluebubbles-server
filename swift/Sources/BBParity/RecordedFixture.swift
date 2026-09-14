//  RecordedFixture
//  One recorded request/response pair, and the corpus of them.
//
//  The corpus under `swift/Fixtures/http` is written by `Tools/conformance-recorder`. This
//  type is the decode half, and the only thing besides the recorder that pins its format;
//  `FixtureReplay` is the drive half.
//
//  See `docs/TESTING.md` § "The parity harness".

import Foundation

/// A recorded HTTP exchange.
///
/// Decoded by hand rather than through `Codable`, because the body is a tagged union whose
/// `value` is arbitrary JSON, and arbitrary JSON is exactly what `Codable` cannot hold
/// without a second `JSONValue`-shaped type that this module would then have to keep in step
/// with `BBSerialization`'s.
public struct RecordedFixture: Sendable {

  public enum Body: Sendable, Equatable {
    case empty
    case json(String)  // Re-encoded, because `[String: Any]` is not Sendable.
    case text(String)
    /// The recorder stores a length and a digest for binary responses, never the bytes.
    case binary(byteLength: Int, sha256: String)

    /// The JSON object, decoded fresh. Nil for every other kind.
    public var jsonObject: [String: Any]? {
      guard case .json(let encoded) = self else { return nil }
      return (try? JSONSerialization.jsonObject(with: Data(encoded.utf8))) as? [String: Any]
    }
  }

  public struct Request: Sendable {
    public let method: String
    /// As recorded, including the query string, whose `password` the recorder redacted.
    public let path: String
    public let headers: [String: String]
    public let body: Body

    /// The path with no query string.
    public var routePath: String {
      String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    /// The query string with the redacted password removed.
    ///
    /// The recorder writes `password=__REDACTED__`, which would authenticate against
    /// nothing. The replay supplies the server-under-test's own credential instead, and
    /// leaving the placeholder in would produce a corpus-wide 401 that looks like an auth
    /// regression rather than a harness detail.
    public var queryItemsWithoutPassword: [URLQueryItem] {
      let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return [] }
      return (URLComponents(string: "?" + parts[1])?.queryItems ?? [])
        .filter { $0.name != "password" }
    }
  }

  public struct Response: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Body
  }

  /// The file's basename, which is how every report names it.
  public let name: String
  public let request: Request
  public let response: Response

  /// Which server answered, inferred from the CORS header it sent.
  ///
  /// This is not a curiosity. A fixture recorded from the Swift server is a photograph of the
  /// candidate, and replaying it proves only that the server still agrees with itself, so
  /// the replay must be able to tell the two apart, and `FixtureCorpusTests` must be able to
  /// fail when a v1 route's only reference is one of these.
  ///
  /// koa-cors sends `access-control-allow-methods` on every response; `CORSMiddleware` sends
  /// it only on `OPTIONS` and sends `access-control-allow-headers` instead. The header is
  /// therefore a reliable fingerprint, and it is the only one in the file; the recorder
  /// does not stamp its source.
  public enum RecordedFrom: String, Sendable {
    case node
    case swift
  }

  public var recordedFrom: RecordedFrom {
    response.headers["access-control-allow-methods"] != nil ? .node : .swift
  }

  public var isV1: Bool { request.routePath.hasPrefix("/api/v1/") }

  /// The same fixture, asking about a different entity.
  ///
  /// A recorded single-entity request names a GUID from the Mac it was recorded on, and the
  /// replay runs against a synthetic database of three chats and seven messages, so
  /// `GET /message/<a real Mac's GUID>` is a 404 here against the reference's 200. The diff
  /// then compares two ERROR envelopes and the entity shape — the whole point of the fixture
  /// — is never looked at. Six fixtures sat in the baseline for exactly this, including both
  /// recordings of `GET /message/:guid`.
  ///
  /// Substituting an identifier that DOES exist is sound because the response shape does not
  /// depend on which row was found: the same serializer runs either way. The VALUES cannot
  /// agree and are not asked to — `.shape` drops them — so what this recovers is precisely
  /// the part the diff can still judge.
  ///
  /// Deliberately a path rewrite rather than a fixture edit: the recorded file stays the
  /// reference's own answer, and the substitution is visible at the call site as a decision
  /// rather than baked into the corpus.
  public func asking(about path: String) -> RecordedFixture {
    let query = self.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    let rewritten = query.count == 2 ? "\(path)?\(query[1])" : path
    return RecordedFixture(
      name: name,
      request: Request(
        method: request.method, path: rewritten,
        headers: request.headers, body: request.body),
      response: response
    )
  }

  /// The recorded path, so a caller can key a substitution off it.
  private var path: String { request.path }
}

extension RecordedFixture {

  /// Decodes one recorded file.
  public static func load(from url: URL) throws -> RecordedFixture {
    let data = try Data(contentsOf: url)
    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let request = root["request"] as? [String: Any],
      let response = root["response"] as? [String: Any],
      let method = request["method"] as? String,
      let path = request["path"] as? String,
      let status = response["status"] as? Int
    else {
      throw CorpusError.malformed(url.lastPathComponent)
    }

    return RecordedFixture(
      name: url.lastPathComponent,
      request: Request(
        method: method,
        path: path,
        headers: lowercasedHeaders(request["headers"]),
        body: try body(from: request["body"], in: url.lastPathComponent)
      ),
      response: Response(
        status: status,
        headers: lowercasedHeaders(response["headers"]),
        body: try body(from: response["body"], in: url.lastPathComponent)
      )
    )
  }

  /// Every fixture in a directory, ordered by name so a report is stable across runs.
  public static func loadAll(from directory: URL) throws -> [RecordedFixture] {
    let files = try FileManager.default
      .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return try files.map(load(from:))
  }

  private static func lowercasedHeaders(_ raw: Any?) -> [String: String] {
    guard let dictionary = raw as? [String: Any] else { return [:] }
    var result: [String: String] = [:]
    for (key, value) in dictionary {
      result[key.lowercased()] = String(describing: value)
    }
    return result
  }

  private static func body(from raw: Any?, in file: String) throws -> Body {
    guard let object = raw as? [String: Any], let kind = object["kind"] as? String else {
      return .empty
    }
    switch kind {
    case "empty":
      return .empty
    case "json":
      let value = object["value"] ?? [:]
      let encoded = try JSONSerialization.data(
        withJSONObject: value, options: [.fragmentsAllowed]
      )
      return .json(String(decoding: encoded, as: UTF8.self))
    case "text":
      return .text(object["value"] as? String ?? "")
    case "binary":
      return .binary(
        byteLength: object["byteLength"] as? Int ?? 0,
        sha256: object["sha256"] as? String ?? ""
      )
    default:
      throw CorpusError.unknownBodyKind(kind, file)
    }
  }

  public enum CorpusError: Error, CustomStringConvertible {
    case malformed(String)
    case unknownBodyKind(String, String)

    public var description: String {
      switch self {
      case .malformed(let file): "\(file) is not a recorded fixture"
      case .unknownBodyKind(let kind, let file): "\(file) has an unknown body kind '\(kind)'"
      }
    }
  }
}
