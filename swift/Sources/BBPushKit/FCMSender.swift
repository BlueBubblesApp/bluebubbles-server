//  FCMSender
//  Notification delivery over FCM HTTP v1.
//
//  The legacy API had `sendMulticast(tokens:)`; HTTP v1 does not — each token is its own
//  request. That reads like a downgrade and is the opposite:
//
//    - **Dead tokens are pruned immediately.** A per-token `UNREGISTERED` says exactly which
//      device is gone, so it can be removed on the spot. Today a dead token lingers until the
//      31-day `purgeOldDevices` sweep, and every notification in between is wasted work.
//    - **One device's failure stops being everyone's.** A payload rejected for one token no
//      longer obscures the outcome for the rest.
//
//  Requests run concurrently and bounded, because a user with many devices should not wait on
//  a serial loop, and an unbounded fan-out is how a slow network turns into thousands of
//  in-flight requests.
//
//  See `docs/EVENTS.md`.

import Foundation
import Logging

public enum NotificationPriority: String, Sendable, Equatable {
  case normal
  case high
}

/// The outcome for one device.
public enum DeliveryOutcome: Sendable, Equatable {
  case delivered
  /// The token is dead. FCM says so explicitly, so the caller removes it now.
  case tokenExpired
  /// Over FCM's 4KB data limit. Not retryable, and not the token's fault.
  case payloadTooLarge
  case failed(reason: String)
}

public struct DeliveryReport: Sendable, Equatable {
  public let outcomes: [String: DeliveryOutcome]

  public init(outcomes: [String: DeliveryOutcome]) {
    self.outcomes = outcomes
  }

  public var deliveredCount: Int {
    outcomes.values.filter { $0 == .delivered }.count
  }
  public var failureCount: Int { outcomes.count - deliveredCount }
  /// Tokens FCM reported as dead. Pruned by the caller immediately.
  public var expiredTokens: [String] {
    outcomes.filter { $0.value == .tokenExpired }.map(\.key).sorted()
  }
}

public actor FCMSender {

  /// FCM's hard limit on a data payload.
  public static let maximumPayloadBytes = 4096
  /// Concurrency ceiling. High enough that a household's devices go out together, low
  /// enough that a stalled network cannot pile up unboundedly.
  public static let maximumConcurrentSends = 8

  private let api: GoogleAPIClient
  private let projectId: String
  private let logger: Logger

  public init(
    api: GoogleAPIClient,
    projectId: String,
    logger: Logger = Logger(label: "bluebubbles.push.fcm")
  ) {
    self.api = api
    self.projectId = projectId
    self.logger = logger
  }

  private var endpoint: String {
    "https://fcm.googleapis.com/v1/projects/\(projectId)/messages:send"
  }

  /// Sends one data payload to many devices.
  ///
  /// - Parameter data: Data-only, as today. A `notification` block would make the OS render
  ///   its own alert, which is not what this app wants — the client builds the notification
  ///   from the payload.
  @discardableResult
  public func send(
    data: [String: String],
    to tokens: [String],
    priority: NotificationPriority = .normal
  ) async throws -> DeliveryReport {
    guard !tokens.isEmpty else { return DeliveryReport(outcomes: [:]) }

    // Checked once rather than per token: the payload is identical for all of them, so
    // failing 30 requests to learn the same fact is pure waste.
    if let size = try? JSONSerialization.data(withJSONObject: data).count,
      size > Self.maximumPayloadBytes
    {
      logger.warning(
        "Notification payload exceeds FCM's size limit",
        metadata: [
          "bytes": .stringConvertible(size),
          "limit": .stringConvertible(Self.maximumPayloadBytes),
        ])
      return DeliveryReport(
        outcomes: Dictionary(uniqueKeysWithValues: tokens.map { ($0, .payloadTooLarge) })
      )
    }

    logger.debug(
      "Sending FCM notification",
      metadata: [
        "devices": .stringConvertible(tokens.count),
        "priority": .string(priority.rawValue),
      ])

    var outcomes: [String: DeliveryOutcome] = [:]
    // A bounded group rather than one task per token.
    await withTaskGroup(of: (String, DeliveryOutcome).self) { group in
      var iterator = tokens.makeIterator()
      var running = 0

      func startNext() {
        guard let token = iterator.next() else { return }
        running += 1
        group.addTask { [self] in
          (token, await deliver(data: data, to: token, priority: priority))
        }
      }

      for _ in 0..<min(Self.maximumConcurrentSends, tokens.count) { startNext() }
      while let (token, outcome) = await group.next() {
        outcomes[token] = outcome
        running -= 1
        startNext()
      }
    }

    let report = DeliveryReport(outcomes: outcomes)
    if report.failureCount > 0 {
      logger.debug(
        "Some notifications were not delivered",
        metadata: [
          "delivered": .stringConvertible(report.deliveredCount),
          "failed": .stringConvertible(report.failureCount),
          "expired": .stringConvertible(report.expiredTokens.count),
        ])
    }
    return report
  }

  private func deliver(
    data: [String: String],
    to token: String,
    priority: NotificationPriority
  ) async -> DeliveryOutcome {
    let message: [String: Any] = [
      "message": [
        "token": token,
        "data": data,
        "android": [
          "priority": priority.rawValue,
          // HTTP v1 takes a duration string in SECONDS. The legacy library took
          // milliseconds — the current server passes `24 * 60 * 60 * 1000` with a
          // comment noting the docs disagree with the library. Here it is "86400s",
          // which is what the v1 API actually documents and accepts.
          "ttl": "86400s",
        ],
      ]
    ]

    do {
      let body = try JSONSerialization.data(withJSONObject: message)
      _ = try await api.send(method: "POST", url: endpoint, body: body)
      return .delivered
    } catch let error as GoogleAPIError {
      return Self.classify(error)
    } catch {
      return .failed(reason: String(describing: error))
    }
  }

  /// Maps FCM's error codes onto outcomes the caller can act on.
  ///
  /// `UNREGISTERED` and `INVALID_ARGUMENT` on a token both mean the device is gone. Treating
  /// them as generic failures is what leaves dead tokens in the database for a month.
  static func classify(_ error: GoogleAPIError) -> DeliveryOutcome {
    guard case .requestFailed(let status, let code, let message) = error else {
      if case .transportFailed(let reason) = error { return .failed(reason: reason) }
      return .failed(reason: String(describing: error))
    }

    switch code {
    case "UNREGISTERED", "NOT_FOUND":
      return .tokenExpired
    case "INVALID_ARGUMENT":
      // Ambiguous: a bad token and a bad payload share this code. The message
      // distinguishes them, and getting it wrong would delete live devices.
      if message.localizedCaseInsensitiveContains("registration token")
        || message.localizedCaseInsensitiveContains("not a valid fcm")
      {
        return .tokenExpired
      }
      return .failed(reason: message)
    default:
      // 404 without a code also means the token is unknown to FCM.
      if status == 404 { return .tokenExpired }
      return .failed(reason: message)
    }
  }
}
