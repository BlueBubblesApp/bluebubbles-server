//  FCMRetryTests
//  A notification that failed for a transient reason gets another go, and one that failed for
//  a permanent reason does not.
//
//  There was no retry at all: one attempt per token. A forty-five second Wi-Fi hiccup dropped
//  every notification that arrived in that window, permanently — and both of `FCMSender`'s
//  failure lines were `debug`, below the default `info`, so a default log bundle contained no
//  evidence either. The user reports that notifications are unreliable and there is nothing to
//  work from.
//
//  The narrowness matters as much as the retry. Retrying a dead token delays the pruning that
//  keeps it out of the database, and retrying an oversized payload re-sends something that
//  will be exactly as oversized next time.

import Foundation
import Testing

@testable import BBPushKit

@Suite("FCM retry")
struct FCMRetryTests {

  // MARK: - The policy

  @Test("Only a transport failure or a server-side status is retried")
  func retryPolicy() {
    // No status at all means the request never reached Google: the network is the failure,
    // and that is the case worth trying again.
    #expect(FCMSender.isRetryable(.failed(reason: "connection lost"), status: nil))
    #expect(FCMSender.isRetryable(.failed(reason: "busy"), status: 503))
    #expect(FCMSender.isRetryable(.failed(reason: "slow down"), status: 429))
    #expect(FCMSender.isRetryable(.failed(reason: "server"), status: 500))
  }

  @Test("A permanent failure is never retried")
  func permanentFailuresAreNotRetried() {
    // A dead token retried is a token that stays in the database longer; the caller prunes on
    // `tokenExpired`, and every retry postpones that.
    #expect(!FCMSender.isRetryable(.tokenExpired, status: 404))
    // Exactly as large on the second attempt.
    #expect(!FCMSender.isRetryable(.payloadTooLarge, status: nil))
    // A malformed request does not become well-formed by being sent again.
    #expect(!FCMSender.isRetryable(.failed(reason: "bad request"), status: 400))
    #expect(!FCMSender.isRetryable(.failed(reason: "forbidden"), status: 403))
    #expect(!FCMSender.isRetryable(.delivered, status: nil))
  }

  // MARK: - Through the sender

  @Test("A 503 is retried, and a later success is reported as delivered")
  func transientFailureIsRetried() async throws {
    // The case the absence of a retry lost outright.
    let http = ScriptedHTTP(responses: [
      (503, Data(#"{"error":{"status":"UNAVAILABLE","message":"busy"}}"#.utf8)),
      (200, Data("{}".utf8)),
    ])
    let sender = try makeRetrySender(http: http)

    let report = try await sender.send(data: ["type": "new-message"], to: ["device-a"])

    #expect(http.callCount == 2, "the failed attempt should have been retried once")
    #expect(report.deliveredCount == 1)
    #expect(report.failureCount == 0)
  }

  @Test("A 400 is not retried")
  func permanentFailureIsNotRetried() async throws {
    let http = ScriptedHTTP(responses: [
      (400, Data(#"{"error":{"status":"INVALID_ARGUMENT","message":"bad payload"}}"#.utf8))
    ])
    let sender = try makeRetrySender(http: http)

    let report = try await sender.send(data: ["type": "new-message"], to: ["device-a"])

    #expect(http.callCount == 1, "a malformed request must not be sent again")
    #expect(report.failureCount == 1)
  }

  @Test("An expired token is not retried, so it can be pruned promptly")
  func expiredTokenIsNotRetried() async throws {
    let http = ScriptedHTTP(responses: [
      (404, Data(#"{"error":{"status":"UNREGISTERED","message":"not registered"}}"#.utf8))
    ])
    let sender = try makeRetrySender(http: http)

    let report = try await sender.send(data: ["type": "new-message"], to: ["device-a"])

    #expect(http.callCount == 1)
    #expect(report.expiredTokens == ["device-a"])
  }

  @Test("Retries are bounded")
  func retriesAreBounded() async throws {
    // A notification is worth a few seconds of persistence, not minutes: one that arrives
    // long enough after the fact is its own kind of wrong. Attempts are the initial one plus
    // the schedule.
    let http = ScriptedHTTP(
      responses: [], fallback: (503, Data(#"{"error":{"status":"UNAVAILABLE"}}"#.utf8)))
    let sender = try makeRetrySender(http: http)

    let report = try await sender.send(data: ["type": "new-message"], to: ["device-a"])

    #expect(http.callCount == FCMSender.retryDelays.count + 1)
    #expect(report.failureCount == 1)
  }
}

/// Answers a scripted sequence, then repeats `fallback` (or the last scripted response).
private final class ScriptedHTTP: HTTPPerforming, @unchecked Sendable {
  private let lock = NSLock()
  private var remaining: [(status: UInt, body: Data)]
  private let fallback: (status: UInt, body: Data)?
  private var _callCount = 0

  var callCount: Int { lock.withLock { _callCount } }

  init(responses: [(status: UInt, body: Data)], fallback: (status: UInt, body: Data)? = nil) {
    self.remaining = responses
    self.fallback = fallback ?? responses.last
  }

  func perform(method: String, url: String, headers: [String: String], body: Data?)
    async throws -> (status: UInt, body: Data)
  {
    lock.withLock {
      _callCount += 1
      if remaining.isEmpty { return fallback ?? (200, Data("{}".utf8)) }
      return remaining.removeFirst()
    }
  }
}

private struct RetryStubExchanger: TokenExchanging {
  func exchange(assertion: String, tokenURI: String) async throws -> AccessToken {
    AccessToken(value: "test-token", expiresAt: Date().addingTimeInterval(3600))
  }
}

private func makeRetrySender(http: ScriptedHTTP) throws -> FCMSender {
  // A real generated key: the token provider signs before any request goes out, so a bogus
  // one fails there and every assertion about the HTTP layer becomes vacuous.
  let key = try TestKey.makePEM()
  let tokens = GoogleTokenProvider(
    account: ServiceAccount(
      projectId: "bluebubbles-test", privateKeyId: "k",
      privateKey: key.pem, clientEmail: "e"
    ),
    exchanger: RetryStubExchanger()
  )
  return FCMSender(
    api: GoogleAPIClient(http: http, tokens: tokens),
    projectId: "bluebubbles-test"
  )
}
