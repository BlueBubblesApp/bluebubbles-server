//  DeliveryAndRestartTests
//  Per-token delivery outcomes, and the bounds on the remote-restart channel.
//
//  NO REAL ADDRESSES OR TOKENS — see CONTRIBUTING.md.

import Foundation
import Testing

@testable import BBPushKit

@Suite("FCM error classification")
struct FCMClassificationTests {

  /// The improvement HTTP v1 buys. A dead token is named, so it can be pruned now rather
  /// than lingering until the 31-day sweep and wasting every notification in between.
  @Test("UNREGISTERED marks the token as expired")
  func unregisteredIsExpired() {
    #expect(
      FCMSender.classify(
        .requestFailed(status: 404, code: "UNREGISTERED", message: "")
      ) == .tokenExpired)
    #expect(
      FCMSender.classify(
        .requestFailed(status: 404, code: "NOT_FOUND", message: "")
      ) == .tokenExpired)
    // A bare 404 means the same thing.
    #expect(
      FCMSender.classify(
        .requestFailed(status: 404, code: nil, message: "")
      ) == .tokenExpired)
  }

  /// `INVALID_ARGUMENT` covers both a bad token and a bad payload. Treating them alike would
  /// delete live devices over a malformed message.
  @Test("INVALID_ARGUMENT is split by what it actually says")
  func invalidArgumentIsDisambiguated() {
    #expect(
      FCMSender.classify(
        .requestFailed(
          status: 400, code: "INVALID_ARGUMENT",
          message: "The registration token is not a valid FCM registration token"
        )) == .tokenExpired)

    let payloadProblem = FCMSender.classify(
      .requestFailed(
        status: 400, code: "INVALID_ARGUMENT", message: "Invalid value at 'message.data'"
      ))
    #expect(payloadProblem != .tokenExpired)
  }

  /// A network problem is not a dead device; pruning on one would delete every token
  /// whenever the connection drops.
  @Test("A transport failure never expires a token")
  func transportFailuresDoNotExpireTokens() {
    let outcome = FCMSender.classify(.transportFailed(reason: "connection refused"))
    #expect(outcome != .tokenExpired)
    if case .failed(let reason) = outcome {
      #expect(reason.contains("connection refused"))
    } else {
      Issue.record("expected a failure outcome")
    }
  }

  @Test("Server errors are failures, not expirations")
  func serverErrorsAreNotExpirations() {
    #expect(
      FCMSender.classify(
        .requestFailed(status: 500, code: "INTERNAL", message: "backend error")
      ) != .tokenExpired)
    #expect(
      FCMSender.classify(
        .requestFailed(status: 503, code: "UNAVAILABLE", message: "try again")
      ) != .tokenExpired)
  }
}

@Suite("Delivery reports")
struct DeliveryReportTests {

  @Test("A report separates delivered, failed and expired")
  func reportShape() {
    let report = DeliveryReport(outcomes: [
      "device-a": .delivered,
      "device-b": .tokenExpired,
      "device-c": .failed(reason: "boom"),
      "device-d": .delivered,
    ])
    #expect(report.deliveredCount == 2)
    #expect(report.failureCount == 2)
    #expect(report.expiredTokens == ["device-b"])
  }

  @Test("An empty send produces an empty report")
  func emptyReport() {
    let report = DeliveryReport(outcomes: [:])
    #expect(report.deliveredCount == 0)
    #expect(report.failureCount == 0)
    #expect(report.expiredTokens.isEmpty)
  }
}

// MARK: - Remote restart

/// Answers with whatever timestamp the test wants.
private actor StubReader {
  var value: Int64?
  init(value: Int64?) { self.value = value }
  func set(_ newValue: Int64?) { value = newValue }
}

@Suite("Remote restart bounds")
struct RemoteRestartTests {

  /// Builds a watcher whose reader is irrelevant — `evaluate` is the decision function and
  /// is tested directly, without a clock or a network.
  private func watcher(
    policy: RemoteRestartPolicy = .default,
    lastHonoured: Int64 = 0,
    reader: RestartCommandReader? = nil,
    onHonoured: @escaping @Sendable (Int64) async -> Void = { _ in }
  ) -> RemoteRestartWatcher {
    RemoteRestartWatcher(
      reader: reader
        ?? RestartCommandReader(
          api: GoogleAPIClient(
            http: NeverCalledHTTP(),
            tokens: GoogleTokenProvider(
              account: ServiceAccount(
                projectId: "p", privateKeyId: "k",
                privateKey: "x", clientEmail: "e"
              ),
              exchanger: NeverCalledExchanger()
            )
          ),
          projectId: "p",
          kind: .firestore
        ),
      policy: policy,
      lastHonoured: lastHonoured,
      onRestart: {},
      onAlert: { _, _ in },
      onHonoured: onHonoured
    )
  }

  private struct NeverCalledHTTP: HTTPPerforming {
    func perform(method: String, url: String, headers: [String: String], body: Data?)
      async throws -> (status: UInt, body: Data)
    {
      Issue.record("the network should not be reached")
      return (500, Data())
    }
  }
  private struct NeverCalledExchanger: TokenExchanging {
    func exchange(assertion: String, tokenURI: String) async throws -> AccessToken {
      AccessToken(value: "", expiresAt: .distantFuture)
    }
  }

  private func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

  /// A fresh, newer command is honoured — the button has to keep working.
  @Test("A fresh command restarts")
  func freshCommandRestarts() async {
    let now = Date()
    let decision = await watcher().evaluate(timestamp: millis(now), now: now)
    #expect(decision == .restart(timestamp: millis(now)))
  }

  /// The bound on vulnerability #4. Without it, anyone who guesses the project ID can hold
  /// the server in a restart loop indefinitely, unauthenticated.
  @Test("A second restart within the hour is refused")
  func rateLimited() async {
    let watcher = watcher()
    let start = Date()

    let first = await watcher.evaluate(timestamp: millis(start), now: start)
    #expect(first == .restart(timestamp: millis(start)))
    // Recorded directly rather than through `poll`, which would reach the network.
    await watcher.recordHonoured(timestamp: millis(start), at: start)

    // A minute later, a brand-new command.
    let later = start.addingTimeInterval(60)
    let second = await watcher.evaluate(timestamp: millis(later), now: later)
    guard case .rateLimited = second else {
      Issue.record("expected the second restart within the hour to be refused, got \(second)")
      return
    }
  }

  /// After the interval, a legitimate request works again — the limit bounds an attack, it
  /// does not disable the feature.
  @Test("A restart is allowed again after the interval")
  func allowedAfterInterval() async {
    let watcher = watcher(policy: RemoteRestartPolicy(minimumInterval: .seconds(1)))
    let start = Date()
    await watcher.recordHonoured(timestamp: millis(start), at: start)

    let later = start.addingTimeInterval(5)
    let decision = await watcher.evaluate(timestamp: millis(later), now: later)
    #expect(decision == .restart(timestamp: millis(later)))
  }

  /// Replay protection. An attacker who captures a valid command must not be able to reuse
  /// it, and the command that caused a restart must not cause another when the server
  /// returns.
  @Test("A command already honoured is ignored")
  func replayIsIgnored() async {
    let now = Date()
    let timestamp = millis(now)
    let decision = await watcher(lastHonoured: timestamp)
      .evaluate(timestamp: timestamp, now: now)
    #expect(decision == .stale(timestamp: timestamp))
  }

  @Test("An older command is ignored even when nothing has been honoured recently")
  func olderCommandIgnored() async {
    let now = Date()
    let decision = await watcher(lastHonoured: millis(now))
      .evaluate(timestamp: millis(now.addingTimeInterval(-60)), now: now)
    guard case .stale = decision else {
      Issue.record("expected an older command to be stale, got \(decision)")
      return
    }
  }

  /// Absolute freshness, independent of ordering: a command from last week is not a request
  /// however new it is relative to the last one honoured.
  @Test("A command outside the freshness window is ignored")
  func staleCommandIgnored() async {
    let now = Date()
    let ancient = millis(now.addingTimeInterval(-86_400))
    let decision = await watcher().evaluate(timestamp: ancient, now: now)
    guard case .tooOld = decision else {
      Issue.record("expected a day-old command to be rejected, got \(decision)")
      return
    }
  }

  /// The compromise that replaces the realtime listener: fast while someone is using the
  /// app, slow when nobody is. A flat 30-second poll would make the button feel broken.
  @Test("Polling is fast while a client is active and slow when idle")
  func adaptivePolling() async {
    let policy = RemoteRestartPolicy(
      activePollInterval: .seconds(5),
      idlePollInterval: .seconds(60),
      activityWindow: .seconds(600)
    )
    let watcher = watcher(policy: policy)
    let now = Date()

    // Nobody has ever connected.
    #expect(await watcher.currentInterval(now: now) == .seconds(60))

    await watcher.noteClientActivity(at: now)
    #expect(await watcher.currentInterval(now: now) == .seconds(5))
    // Still within the activity window.
    #expect(await watcher.currentInterval(now: now.addingTimeInterval(300)) == .seconds(5))
    // Past it.
    #expect(await watcher.currentInterval(now: now.addingTimeInterval(900)) == .seconds(60))
  }

  /// The replay guard is only a guard if it SURVIVES the restart it guards against.
  ///
  /// It was persisted by reading `honouredTimestamp` immediately after `start()` returned —
  /// and `start()` returns as soon as the poll task is spawned, so what got written was the
  /// value the watcher was constructed with, every time, and never the one it acted on. A
  /// restart honoured at 10:00 was therefore honoured again the moment the server came back,
  /// which is the restart loop the freshness window exists to prevent.
  @Test("The honoured timestamp is persisted when a command is acted on")
  func honouredTimestampIsPersisted() async throws {
    let now = Date()
    let timestamp = millis(now)
    let persisted = Persisted()

    let watcher = watcher(
      reader: RestartCommandReader(
        api: GoogleAPIClient(
          http: FixedResponseHTTP(
            body: Data("{\"fields\":{\"nextRestart\":{\"integerValue\":\"\(timestamp)\"}}}".utf8)
          ),
          tokens: StaticTokenProvider(value: "token")
        ),
        projectId: "p",
        kind: .firestore
      ),
      onHonoured: { value in await persisted.record(value) }
    )

    let decision = try await watcher.poll(now: now)
    #expect(decision == .restart(timestamp: timestamp))
    #expect(await persisted.values == [timestamp])
  }

  /// A command that is refused must not be persisted — writing it would mark an attacker's
  /// rejected command as the newest one honoured, and silently retire every later
  /// legitimate request below it.
  @Test("A refused command is not persisted")
  func refusedCommandIsNotPersisted() async throws {
    let now = Date()
    let ancient = millis(now.addingTimeInterval(-86_400))
    let persisted = Persisted()

    let watcher = watcher(
      reader: RestartCommandReader(
        api: GoogleAPIClient(
          http: FixedResponseHTTP(
            body: Data("{\"fields\":{\"nextRestart\":{\"integerValue\":\"\(ancient)\"}}}".utf8)
          ),
          tokens: StaticTokenProvider(value: "token")
        ),
        projectId: "p",
        kind: .firestore
      ),
      onHonoured: { value in await persisted.record(value) }
    )

    _ = try await watcher.poll(now: now)
    #expect(await persisted.values.isEmpty)
  }

  private actor Persisted {
    private(set) var values: [Int64] = []
    func record(_ value: Int64) { values.append(value) }
  }

  private struct FixedResponseHTTP: HTTPPerforming {
    let body: Data
    func perform(method: String, url: String, headers: [String: String], body: Data?)
      async throws -> (status: UInt, body: Data)
    {
      (200, self.body)
    }
  }
}
