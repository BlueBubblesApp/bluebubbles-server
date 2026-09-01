//  ScheduledMessageService
//  Actually sending the messages people scheduled.
//
//  `ScheduleInterface` is CRUD and nothing else: the routes create, list, update and delete
//  rows, and until this existed nothing ever read one back and acted on it. A user could
//  schedule a message, see it listed as `pending`, and it would stay pending forever. The
//  feature looked complete from every side except the one that matters.
//
//  Polled rather than timer-per-row, which is what the current service does. A timer per
//  scheduled message means the set of live timers has to be kept in step with the table
//  through every create, update, delete and restart — and a missed reschedule is a message
//  that silently never sends. A poll re-reads the truth every tick and cannot drift; the
//  cost is a single indexed query a minute, on a column that is already indexed.
//
//  See `.claude/docs/architecture.md`.

import BBEvents
import BBHandlers
import BBInterfaces
import BBSerialization
import BBServiceKit
import BBSettings
import Foundation
import GRDB
import Logging

/// How a recurring schedule repeats. Transcribed from
/// `ScheduledMessageScheduleRecurringType` — the values are client-facing and frozen.
enum RecurrenceInterval: String, Sendable {
  case hourly, daily, weekly, monthly, yearly

  /// The current server computes these as fixed multiples of a day, including for months
  /// and years. Reproduced rather than corrected to calendar arithmetic: a client that
  /// scheduled "monthly" against the old server expects the same instants, and quietly
  /// moving them is a behaviour change nobody asked for.
  var seconds: TimeInterval {
    switch self {
    case .hourly: 3600
    case .daily: 86_400
    case .weekly: 604_800
    case .monthly: 2_592_000
    case .yearly: 31_536_000
    }
  }
}

final class ScheduledMessageService: ContextualService {

  static let manifest = BuiltInManifests.scheduledMessages
  /// A failure here is a failure to read the database, and retrying immediately fails the
  /// same way. The poll loop recovers on its own tick.
  static let restartPolicy = RestartPolicy.never

  /// A minute. The current server's timers are exact to the millisecond; a poll is exact
  /// to the interval, which for a message someone scheduled hours ahead is not a
  /// difference anyone can perceive.
  static let pollInterval: Duration = .seconds(60)

  let context: AppContext
  private let pump = TaskBox()

  /// The only path this service takes to the table. It used to run its own UPDATEs.
  private var store: ScheduledMessageRepository {
    ScheduledMessageRepository(database: context.appDatabase)
  }

  init(host: AppContext) { self.context = host }

  func start() async throws {
    let interval = Self.pollInterval
    // The loop sweeps BEFORE its first sleep, so anything that came due while the server
    // was down goes out now rather than a minute from now. Deliberately the only sweep:
    // calling `dispatchDue()` here as well ran it twice within the same second, and the
    // second pass could read a row the first had not finished marking — which sends the
    // same message to a real person twice.
    await pump.set(
      Task { [weak self] in
        while !Task.isCancelled {
          await self?.dispatchDue()
          try? await Task.sleep(for: interval)
        }
      })
  }

  func stop() async { await pump.cancel() }

  var health: ServiceHealth { get async { await pump.isRunning ? .running : .stopped } }

  // MARK: - Dispatch

  func dispatchDue(now: Date = Date()) async {
    let logger = context.logger
    let due: [ScheduledMessage]
    do {
      due = try await store.due(at: now)
    } catch {
      logger.warning(
        "Could not read due scheduled messages",
        metadata: [
          "error": .string(String(describing: error))
        ])
      return
    }

    for record in due {
      await send(record, now: now)
    }
  }

  private func send(_ record: ScheduledMessage, now: Date) async {
    let logger = context.logger
    guard let id = record.id else { return }

    // The next occurrence is computed and stored BEFORE the send is attempted. If the
    // send throws — or the process dies mid-send — the row is already moved on, so a
    // recurring message cannot re-fire on the next tick and spam the recipient. That
    // ordering is what the current service does, and for the same reason.
    let next = Self.nextOccurrence(after: record, from: now)

    var outcome = ScheduledMessageStatus.sent
    var failure: String?

    do {
      try await perform(record)
    } catch {
      outcome = .failed
      failure = String(describing: error)
      logger.warning(
        "A scheduled message failed to send",
        metadata: [
          "id": .stringConvertible(id),
          "error": .string(failure ?? ""),
        ])
    }

    do {
      try await store.recordOutcome(
        id: id, nextOccurrence: next, outcome: outcome, failure: failure, at: now
      )
    } catch {
      logger.error(
        "Could not record a scheduled message's outcome",
        metadata: [
          "id": .stringConvertible(id),
          "error": .string(String(describing: error)),
        ])
    }

    // Clients surface these, and the event names are frozen.
    await context.events.emit(
      ServerEvent(
        name: outcome == .sent ? .scheduledMessageSent : .scheduledMessageError,
        fullPayload: record.json,
        notificationPayload: record.json
      )
    )
  }

  /// Performs the row's action.
  private func perform(_ record: ScheduledMessage) async throws {
    guard record.type == "send-message" else {
      // The only type the current server defines. An unknown one is recorded as a
      // failure rather than skipped, so it does not sit pending forever looking like
      // it is about to happen.
      throw ServiceStartupError.unavailable("unknown scheduled message type '\(record.type)'")
    }

    let payload = try JSONValue.parse(record.payload)
    guard let chatGUID = payload["chatGuid"]?.stringValue, !chatGUID.isEmpty else {
      throw ServiceStartupError.unavailable("the scheduled payload has no chatGuid")
    }
    let interfaces = try await context.requireInterfaces()

    _ = try await interfaces.message.sendText(
      MessageInterface.SendTextRequest(
        chatGUID: chatGUID,
        text: payload["message"]?.stringValue ?? "",
        subject: payload["subject"]?.stringValue,
        effectID: payload["effectId"]?.stringValue,
        replyToGUID: payload["selectedMessageGuid"]?.stringValue,
        partIndex: payload["partIndex"]?.intValue ?? 0
      )
    )
  }

  /// When a recurring schedule next fires, or nil for a one-shot.
  ///
  /// Advanced past `now` rather than by a single interval: a server that was off for a
  /// week must not wake up and fire seven days of a daily schedule one tick apart.
  static func nextOccurrence(
    after record: ScheduledMessage,
    from now: Date
  ) -> Date? {
    guard let blob = record.schedule,
      let schedule = try? JSONValue.parse(blob),
      schedule["type"]?.stringValue == "recurring",
      let raw = schedule["intervalType"]?.stringValue,
      let interval = RecurrenceInterval(rawValue: raw)
    else { return nil }

    let multiplier = max(1, schedule["interval"]?.intValue ?? 1)
    let step = interval.seconds * Double(multiplier)
    guard step > 0 else { return nil }

    var next = record.scheduledFor.addingTimeInterval(step)
    while next <= now {
      next = next.addingTimeInterval(step)
    }
    return next
  }
}
