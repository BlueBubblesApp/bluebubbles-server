//  ParityRequest
//  One request the parity harness sends, and the one place it becomes a `URLRequest`.
//
//  Three drivers send recorded or listed requests at a server under test: `FixtureReplay`
//  (the recorded corpus), `SideBySideRunner` (two live servers) and the replay suite's own
//  seeding and probing. All three build through this type, so "the request the harness
//  sent" is one thing rather than three copies free to disagree about the query, the
//  password or the body. A request that cannot be built or sent THROWS: a swallowed failure
//  surfaces later as an unrelated 404 that the diff then scores as a server's answer.
//
//  The server's credential always travels as `?password=`, because that is the one scheme
//  every server the harness drives accepts, and a recorded `password=__REDACTED__` is
//  dropped before it is replaced. Recorded request headers are not replayed: the recorder
//  keeps them for provenance, and the only header the comparison depends on is the
//  content type, which follows from the body.

import Foundation

public struct ParityRequest: Sendable {
  public let method: String
  /// The route path with no query string: `/api/v1/message/query`.
  public let path: String
  /// The query, in the order it is sent, without any `password` item.
  public let query: [URLQueryItem]
  /// A JSON body, sent with `Content-Type: application/json`.
  public let jsonBody: String?

  public init(method: String, path: String, query: [URLQueryItem] = [], jsonBody: String? = nil) {
    self.method = method
    self.path = path
    self.query = query.filter { $0.name != "password" }
    self.jsonBody = jsonBody
  }

  /// A recorded fixture's request, with its redacted password removed. Only a JSON body is
  /// carried; a text body is a multipart upload the recorder could not store byte-exactly,
  /// and `FixtureReplay` refuses those before it gets here.
  public init(_ fixture: RecordedFixture) {
    let body: String?
    if case .json(let encoded) = fixture.request.body { body = encoded } else { body = nil }
    self.init(
      method: fixture.request.method, path: fixture.request.routePath,
      query: fixture.request.queryItemsWithoutPassword, jsonBody: body)
  }

  /// A side-by-side corpus entry. Its query is a dictionary, so it is sorted by name and the
  /// request is the same on every run rather than in whatever order the hash fell.
  public init(_ request: CorpusRequest) {
    self.init(
      method: request.method.rawValue, path: request.path,
      query: request.query.map { URLQueryItem(name: $0.key, value: $0.value) }
        .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") },
      jsonBody: request.body)
  }

  /// The request against `baseURL`, authenticated with `password`.
  ///
  /// - Throws: `ParityRequestError.badURL` when the base and path do not form a URL.
  public func urlRequest(baseURL: String, password: String) throws -> URLRequest {
    let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    guard var components = URLComponents(string: base + path) else {
      throw ParityRequestError.badURL(base + path)
    }
    components.queryItems = query + [URLQueryItem(name: "password", value: password)]
    guard let url = components.url else { throw ParityRequestError.badURL(base + path) }

    var request = URLRequest(url: url)
    request.httpMethod = method
    if let jsonBody {
      request.httpBody = Data(jsonBody.utf8)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }

  /// Sends the request and returns the status and the body's bytes.
  ///
  /// - Throws: `ParityRequestError.badURL`, whatever the session throws, and
  ///   `ParityRequestError.notHTTP` for a response that is not HTTP, which would otherwise
  ///   be scored as status 0 and compared as though a server had said it.
  public func send(
    to baseURL: String, password: String, session: URLSession
  ) async throws -> (status: Int, data: Data) {
    let request = try urlRequest(baseURL: baseURL, password: password)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ParityRequestError.notHTTP(method: method, path: path)
    }
    return (http.statusCode, data)
  }
}

public enum ParityRequestError: Error, Sendable, CustomStringConvertible, LocalizedError {
  case badURL(String)
  case notHTTP(method: String, path: String)

  public var description: String {
    switch self {
    case .badURL(let url): "Could not build a URL from \(url)"
    case .notHTTP(let method, let path): "\(method) \(path) did not get an HTTP response"
    }
  }

  public var errorDescription: String? { description }
}
