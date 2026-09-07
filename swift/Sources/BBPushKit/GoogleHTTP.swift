//  GoogleHTTP
//  The REST plumbing under everything else in this module.
//
//  There is no Swift `firebase-admin`, so every Google interaction here is an HTTP request.
//  Concentrating them in one place means authentication, retry and error decoding are written
//  once rather than per API.
//
//  See `docs/EVENTS.md`.

import AsyncHTTPClient
import BBCore
import Foundation
import Logging
import NIOCore
import NIOFoundationCompat

public enum GoogleAPIError: BBError {
  /// A non-2xx response. `status` and `message` come from Google's error envelope when it
  /// supplies one, which it usually does and which is far more useful than the status alone.
  case requestFailed(status: UInt, code: String?, message: String)
  case transportFailed(reason: String)
  case decodingFailed(reason: String)

  var isAuthenticationFailure: Bool {
    if case .requestFailed(let status, _, _) = self { return status == 401 || status == 403 }
    return false
  }
}

/// Minimal HTTP surface, behind a protocol so every API client above can be tested without a
/// network.
public protocol HTTPPerforming: Sendable {
  func perform(
    method: String,
    url: String,
    headers: [String: String],
    body: Data?
  ) async throws -> (status: UInt, body: Data)
}

/// AsyncHTTPClient-backed implementation.
public struct AsyncHTTPPerformer: HTTPPerforming {

  private let client: HTTPClient
  private let timeout: TimeAmount

  public init(client: HTTPClient = .shared, timeout: TimeAmount = .seconds(30)) {
    self.client = client
    self.timeout = timeout
  }

  public func perform(
    method: String,
    url: String,
    headers: [String: String],
    body: Data?
  ) async throws -> (status: UInt, body: Data) {
    var request = HTTPClientRequest(url: url)
    request.method = .init(rawValue: method)
    for (name, value) in headers { request.headers.add(name: name, value: value) }
    if let body { request.body = .bytes(ByteBuffer(data: body)) }

    do {
      let response = try await client.execute(request, timeout: timeout)
      // Capped: an error page from a captive portal or a proxy can be arbitrarily large,
      // and none of these APIs answer with more than a few hundred kilobytes.
      let buffer = try await response.body.collect(upTo: 4 * 1024 * 1024)
      return (UInt(response.status.code), Data(buffer.readableBytesView))
    } catch {
      throw GoogleAPIError.transportFailed(reason: String(describing: error))
    }
  }
}

// MARK: - Authenticated calls

/// Issues authenticated requests against Google's APIs.
public struct GoogleAPIClient: Sendable {

  private let http: any HTTPPerforming
  /// Any token source, not `GoogleTokenProvider` specifically — that concrete type is what
  /// kept the interactive setup flow from being able to use this client at all.
  private let tokens: any AccessTokenProviding
  private let logger: Logger

  public init(
    http: any HTTPPerforming,
    tokens: any AccessTokenProviding,
    logger: Logger = Logger(label: "bluebubbles.push.api")
  ) {
    self.http = http
    self.tokens = tokens
    self.logger = logger
  }

  /// Performs a request, retrying once on an authentication failure with a fresh token.
  ///
  /// The retry is not generic resilience — it is specifically for a token Google has
  /// decided to stop honouring early, which does happen (key rotation, revoked grants). Any
  /// other failure is returned as-is, because retrying a 400 just produces another 400.
  @discardableResult
  public func send(
    method: String,
    url: String,
    body: Data? = nil,
    extraHeaders: [String: String] = [:]
  ) async throws -> Data {
    do {
      return try await attempt(method: method, url: url, body: body, extraHeaders: extraHeaders)
    } catch let error as GoogleAPIError where error.isAuthenticationFailure {
      logger.debug("Google rejected the access token; re-minting and retrying once")
      await tokens.invalidate()
      return try await attempt(method: method, url: url, body: body, extraHeaders: extraHeaders)
    }
  }

  private func attempt(
    method: String,
    url: String,
    body: Data?,
    extraHeaders: [String: String]
  ) async throws -> Data {
    let token = try await tokens.token()
    var headers = extraHeaders
    headers["Authorization"] = "Bearer \(token.value)"
    headers["Accept"] = "application/json"
    if body != nil { headers["Content-Type"] = "application/json" }

    let (status, data) = try await http.perform(
      method: method, url: url, headers: headers, body: body
    )
    guard (200...299).contains(status) else {
      throw Self.decodeError(status: status, body: data)
    }
    return data
  }

  /// Google's error envelope is `{"error": {"code": …, "status": …, "message": …}}`.
  /// Reading it turns "403" into something a user can act on.
  static func decodeError(status: UInt, body: Data) -> GoogleAPIError {
    struct Envelope: Decodable {
      struct Failure: Decodable {
        let status: String?
        let message: String?
      }
      let error: Failure?
    }
    let decoded = try? JSONDecoder().decode(Envelope.self, from: body)
    return .requestFailed(
      status: status,
      code: decoded?.error?.status,
      message: decoded?.error?.message
        ?? String(decoding: body.prefix(512), as: UTF8.self)
    )
  }
}

// MARK: - Token exchange

/// Exchanges a signed assertion at Google's token endpoint.
public struct GoogleTokenExchanger: TokenExchanging {

  private let http: any HTTPPerforming

  public init(http: any HTTPPerforming) {
    self.http = http
  }

  public func exchange(assertion: String, tokenURI: String) async throws -> AccessToken {
    // Form-encoded, not JSON — RFC 7523 §2.1, and Google enforces it.
    let form = [
      "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer",
      "assertion=\(assertion)",
    ].joined(separator: "&")

    let (status, data) = try await http.perform(
      method: "POST",
      url: tokenURI,
      headers: ["Content-Type": "application/x-www-form-urlencoded"],
      body: Data(form.utf8)
    )

    guard (200...299).contains(status) else {
      throw GoogleAuthError.tokenRequestFailed(
        status: status,
        body: String(decoding: data.prefix(512), as: UTF8.self)
      )
    }

    struct Response: Decodable {
      let accessToken: String
      let expiresIn: Int
      enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
      }
    }
    guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
      throw GoogleAuthError.malformedTokenResponse
    }
    return AccessToken(
      value: response.accessToken,
      expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn))
    )
  }
}

extension GoogleAPIError {
  public var code: String {
    switch self {
    case .requestFailed: "google.request_failed"
    case .transportFailed: "google.transport_failed"
    case .decodingFailed: "google.decoding_failed"
    }
  }

  public var domain: String { "Push" }

  public var title: String { "A request to Google failed" }

  public var body: String {
    switch self {
    case .requestFailed(let status, let code, let message):
      code.map { "Google returned \(status) \($0): \(message)" }
        ?? "Google returned \(status): \(message)"
    case .transportFailed(let reason):
      "The request never reached Google: \(reason)"
    case .decodingFailed(let reason):
      "Google's reply could not be read: \(reason)"
    }
  }

  public var context: [String: DiagnosticValue] {
    if case .requestFailed(let status, _, _) = self { return ["status": .int(Int(status))] }
    return [:]
  }
}
