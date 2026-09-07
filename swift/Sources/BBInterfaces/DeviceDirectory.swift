//  DeviceDirectory
//  Registered push targets, read and pruned by the delivery path.
//
//  A thin layer over `DeviceRepository` whose entire job is the FAILURE policy: every method
//  here logs and carries on rather than throwing. That is right for these callers and wrong in
//  general, which is why it is a separate type rather than behaviour added to the repository —
//  the settings screen listing devices wants the error, and the notification loop reacting to
//  FCM's report of a dead token does not.
//
//  It moved off `AppContext`, where the same three methods sat as wrappers. A dependency
//  container holding a reference is one thing; a container that knows what to do when a delete
//  fails is another, and it was the second.

import BBDiagnostics
import BBPersistence
import Foundation
import Logging

/// The registered push tokens, with a "log and carry on" failure policy.
public struct DeviceDirectory: Sendable {

  private let repository: DeviceRepository
  private let logger: Logger

  public init(
    repository: DeviceRepository,
    logger: Logger = Logger(label: "bluebubbles.devices")
  ) {
    self.repository = repository
    self.logger = logger
  }

  /// Every registered push token, read fresh on each notification.
  ///
  /// An unreadable database gives back an empty list. The caller is a delivery loop with a
  /// message in hand and nothing useful to do about a failed read.
  public func tokens() async -> [String] {
    do {
      return try await repository.tokens()
    } catch {
      logger.warning(
        "Could not read registered devices",
        metadata: ["error": .string(String(describing: error))])
      return []
    }
  }

  /// Removes devices FCM reported as unregistered.
  ///
  /// Immediate, rather than waiting for the 31-day sweep the reference relies on — every
  /// notification to a dead token in between is wasted work.
  public func prune(tokens: [String]) async {
    guard !tokens.isEmpty else { return }
    do {
      let removed = try await repository.prune(tokens: tokens)
      logger.info(
        "Pruned unregistered devices", metadata: ["count": .stringConvertible(removed)])
    } catch {
      logger.warning(
        "Could not prune unregistered devices",
        metadata: ["error": .string(String(describing: error))])
    }
  }

  /// Drops every registered device, after a Firebase project change.
  ///
  /// The tokens are scoped to the old project and would silently deliver nowhere, which is
  /// worse than having none: the count on screen would say push is reaching people.
  public func removeAll() async {
    do {
      try await repository.deleteAll()
      logger.info("Cleared registered devices after a Firebase project change")
    } catch {
      logger.warning(
        "Could not clear registered devices",
        metadata: ["error": .string(String(describing: error))])
    }
  }
}
