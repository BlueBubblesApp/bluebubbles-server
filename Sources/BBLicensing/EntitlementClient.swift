//  EntitlementClient
//  One POST: a license key and a machine fingerprint, in; a signed token, out.
//
//  This is the whole of what the server knows about the vendor. Which payment processor sits
//  behind the endpoint, how a product maps onto a tier, what a subscription costs — none of it
//  is expressible here, and that is the point. Changing processor is a change to the issuing
//  function; this file, the token format, the settings keys and every test above them are
//  untouched.
//
//  The KEY leaves the machine here and nowhere else. It goes to our issuer over HTTPS and is
//  never written to a log, an alert or a response body.
//
//  A failure is a normal outcome, not an exception: a Mac asleep, a rebooted router, our
//  endpoint restarting. Every one of them lands as a thrown error that the caller counts and
//  otherwise ignores, because the token already in hand stays valid for its window.

import BBCore
import BBLicense
import Foundation

/// Why one exchange with the issuer failed.
///
/// Its `body` is what the `license.refresh_failed` audit record carries as its reason, which
/// an operator reads. The Subscription page does not show it: what a person is told there
/// comes from `SubscriptionPolicy`, which says the same thing for every one of these.
public enum EntitlementClientError: BBError, Equatable {
  case badEndpoint(String)
  /// The request never got an answer. Carries the transport's own sentence.
  case transport(String)
  /// The issuer answered, and refused THIS request: a 4xx that is not about load. The only
  /// failure that says anything about the KEY rather than about the network.
  case rejected(status: Int, reason: String?)
  /// The issuer answered, and could not serve the request right now: a 5xx, a 408 or a 429.
  /// Said nothing about the key. Folded into `rejected`, a refused key and an issuer outage
  /// were the same failure, and the page told a person with a mistyped key to check their
  /// internet connection for ever.
  case issuerUnavailable(status: Int)
  case malformedResponse(String)

  public var code: String {
    switch self {
    case .badEndpoint: "license.bad_endpoint"
    case .transport: "license.transport"
    case .rejected: "license.rejected"
    case .issuerUnavailable: "license.issuer_unavailable"
    case .malformedResponse: "license.malformed_response"
    }
  }

  public var domain: String { "Subscription" }
  public var title: String { "The subscription could not be checked" }

  public var body: String {
    switch self {
    case .badEndpoint(let endpoint):
      "The license service address is not usable: \(endpoint)"
    case .transport(let detail):
      "The license service could not be reached: \(detail)"
    case .rejected(let status, let reason?):
      "The license service refused the request (HTTP \(status)): \(reason)"
    case .rejected(let status, nil):
      "The license service refused the request (HTTP \(status))."
    case .issuerUnavailable(let status):
      "The license service could not answer just now (HTTP \(status))."
    case .malformedResponse(let detail):
      "The license service answered with something this server could not read: \(detail)"
    }
  }
}

/// What the issuer answers.
public struct EntitlementResponse: Sendable, Equatable {
  /// The signed token, compact form.
  public let token: String
  /// Set when the issuer wants this license treated as disabled. Separate from an HTTP error
  /// because it is a durable fact to persist, not a request that failed.
  public let isRevoked: Bool

  public init(token: String, isRevoked: Bool) {
    self.token = token
    self.isRevoked = isRevoked
  }
}

public struct EntitlementClient: Sendable {

  /// Injected so tests never reach the network and so the transport stays swappable.
  public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  private let endpoint: String
  private let transport: Transport
  private let serverVersion: String

  public init(
    endpoint: String,
    serverVersion: String,
    transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
  ) {
    self.endpoint = endpoint
    self.serverVersion = serverVersion
    self.transport = transport
  }

  public func exchange(key: String, machine: String) async throws -> EntitlementResponse {
    guard let url = URL(string: endpoint), url.scheme?.hasPrefix("http") == true else {
      throw EntitlementClientError.badEndpoint(endpoint)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // Short, and off the request path by construction: this only ever runs on the refresh
    // timer, so nothing is waiting on it. Long enough to survive a slow cold start at the
    // other end.
    request.timeoutInterval = 20
    // A cached entitlement is a stale entitlement; the whole purpose of the call is to learn
    // something new.
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      // `key`, not `license_key`: this is the issuer's request field, and spelling it the
      // same as the settings key would make two unrelated things read as one.
      "key": key,
      "machine_id": machine,
      "server_version": serverVersion,
    ])

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport(request)
    } catch {
      // The transport's sentence, not its dump: it reaches the audit record. What the
      // Subscription page says is `SubscriptionPolicy`'s, never this.
      throw EntitlementClientError.transport(DiagnosticText.sentence(for: error))
    }

    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      guard Self.isRefusal(status) else {
        throw EntitlementClientError.issuerUnavailable(status: status)
      }
      let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"]
      throw EntitlementClientError.rejected(status: status, reason: reason as? String)
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw EntitlementClientError.malformedResponse("response is not a JSON object")
    }
    let isRevoked = object["revoked"] as? Bool ?? false
    let token = object["token"] as? String ?? ""

    // A REVOCATION LEGITIMATELY CARRIES NO TOKEN. There is no entitlement to describe, so the
    // issuer sends `{"token": null, "revoked": true}` and there is nothing for it to put
    // there. Requiring a token here made a refund unreportable: the guard threw
    // `malformedResponse`, `refresh()` recorded it as `.failed`, `markRevoked()` never ran,
    // and the customer kept paid features until the token aged out — at which point they were
    // told their subscription "could not be confirmed" rather than that it had been revoked.
    guard !isRevoked else {
      return EntitlementResponse(token: "", isRevoked: true)
    }

    // On a SUCCESS a missing token is still malformed. That is a broken issuer, not a
    // revocation, and quietly treating it as one would disable a paying customer.
    guard !token.isEmpty else {
      throw EntitlementClientError.malformedResponse("no token in response")
    }
    return EntitlementResponse(token: token, isRevoked: false)
  }

  /// Whether a status is the issuer refusing the request, as opposed to failing to serve
  /// it: a 4xx, other than a timeout or a rate limit, which are about the moment.
  static func isRefusal(_ status: Int) -> Bool {
    (400..<500).contains(status) && status != 408 && status != 429
  }
}
