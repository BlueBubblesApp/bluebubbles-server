//  ScheduledMessageService
//  Actually sending the messages people scheduled.
//
//  `ScheduleInterface` is CRUD and nothing else: the routes create, list, update and delete
//  rows. This is what reads a row back and acts on it.
//
//  Polled rather than timer-per-row. A timer per
//  scheduled message means the set of live timers has to be kept in step with the table
//  through every create, update, delete and restart, and a missed reschedule is a message
//  that silently never sends. A poll re-reads the truth every tick and cannot drift; the
//  cost is a single indexed query a minute, on a column that is already indexed.
//
//  See `.claude/docs/architecture.md`.

import BBBuiltIns
import BBCore
import BBEvents
import BBInterfaces
import BBPersistence
import BBSerialization
import BBServiceKit
import BBSettings
import Foundation
import GRDB
import Logging

/// How a recurring schedule repeats. Transcribed from
/// `ScheduledMessageScheduleRecurringType`: the values are client-facing and frozen.
enum RecurrenceInterval: String, Sendable {
  case hourly, daily, weekly, monthly, yearly

  /// The calendar unit one interval is. Calendar arithmetic rather than fixed seconds:
  /// "monthly on the 31st" lands on the 31st, "yearly" survives a leap year, and "daily at
  /// nine" is still at nine after the clocks change. The old server counted a month as 30
  /// days and a year as 365, which put "monthly" on a different day every month.
  var component: Calendar.Component {
    switch self {
    case .hourly: .hour
    case .daily: .day
    case .weekly: .weekOfYear
    case .monthly: .month
    case .yearly: .year
    }
  }

  /// The most seconds one interval can span, for estimating how many have elapsed.
  ///
  /// An upper bound on purpose: dividing elapsed time by it UNDERestimates the count, and
  /// an underestimate is corrected by walking forward, where an overestimate would skip an
  /// occurrence. A day can be 25 hours across a clock change, a month 31 days, a year 366.
  var longestSeconds: TimeInterval {
    switch self {
    case .hourly: 3600
    case .daily: 25 * 3600
    case .weekly: 7 * 24 * 3600 + 3600
    case .monthly: 31 * 24 * 3600 + 3600
    case .yearly: 366 * 24 * 3600 + 3600
    }
  }
}

actor ScheduledMessageService: Service {

  static let manifest = BuiltInManifests.scheduledMessages
  /// A failure here is a failure to read the database, and retrying immediately fails the
  /// same way. The poll loop recovers on its own tick.
  static let restartPolicy = RestartPolicy.never

  /// A minute. The current server's timers are exact to the millisecond; a poll is exact
  /// to the interval, which for a message someone scheduled hours ahead is not a
  /// difference anyone can perceive.
  static let pollInterval: Duration = .seconds(60)

  /// What this service touches, rather than the container that holds it.
  typealias Host = any InterfaceProviding & LoggerProviding & EventPublishing
    & AppDatabaseProviding

  private let host: Host
  private let appDatabase: AppDatabase
  private let events: EventBus
  private let logger: Logger
  private var pump: Task<Void, Never>?

  /// The only path this service takes to the table; it runs no SQL of its own.
  private var store: ScheduledMessageRepository {
    ScheduledMessageRepository(database: appDatabase)
  }

  init(host: Host) {
    self.host = host
    self.appDatabase = host.appDatabase
    self.events = host.events
    self.logger = Logger(label: "bluebubbles.scheduled")
  }

  func start() async throws {
    let interval = Self.pollInterval
    logger.info(
      "Scheduled message dispatcher running",
      metadata: ["intervalS": .stringConvertible(Int(interval.seconds))])
    // The loop sweeps BEFORE its first sleep, so anything that came due while the server
    // was down goes out now rather than a minute from now. Deliberately the only sweep: a
    // second `dispatchDue()` within the same second could read a row the first has not
    // finished marking, which sends the same message to a real person twice.
    pump?.cancel()
    pump = Task { [weak self] in
      while !Task.isCancelled {
        await self?.dispatchDue()
        try? await Task.sleep(for: interval)
      }
    }
  }

  func stop() async {
    pump?.cancel()
    pump = nil
  }

  var health: ServiceHealth { get async { pump != nil ? .running : .stopped } }

  // MARK: - Dispatch

  func dispatchDue(now: Date = Date()) async {
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

    if !due.isEmpty {
      logger.debug(
        "Dispatching due scheduled messages", metadata: ["count": .stringConvertible(due.count)])
    }
    for record in due {
      await send(record, now: now)
    }
  }

  private func send(_ record: ScheduledMessage, now: Date) async {
    guard let id = record.id else { return }

    // The next occurrence is computed and STORED before the send is attempted, so an
    // interrupted send leaves the row moved on rather than due. Only the computing used to
    // happen first: `recordOutcome` ran after `perform`, so a crash, an out-of-memory kill
    // or a `replaceProcess()` mid-send left the row untouched and the next sweep sent the
    // same message to a real person again. The comment here described this ordering for
    // months without it being implemented.
    let next = Self.nextOccurrence(after: record, from: now)

    do {
      try await store.claimForDispatch(id: id, nextOccurrence: next, at: now)
    } catch {
      // The claim is what makes this safe to attempt, so a claim that failed means NOT
      // attempting it: the alternative is sending with no record that we did, which is the
      // duplicate this whole ordering exists to prevent. It stays due and the next tick
      // tries again.
      logger.warning(
        "Could not claim a scheduled message; it will be retried",
        metadata: [
          "id": .stringConvertible(id),
          "error": .string(String(describing: error)),
        ])
      return
    }

    var outcome = ScheduledMessageStatus.sent
    var failure: String?

    do {
      try await perform(record)
      logger.info(
        "Scheduled message sent",
        metadata: [
          "id": .stringConvertible(id),
          "type": .string(record.type),
          "next": .string(next.map { "\($0)" } ?? "none"),
        ])
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
    await events.emit(
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
      // The only type the reference defines. An unknown one is recorded as a
      // failure rather than skipped, so it does not sit pending forever looking like
      // it is about to happen.
      throw ServiceStartupError.unavailable("unknown scheduled message type '\(record.type)'")
    }

    let payload = try JSONValue.parse(record.payload)
    guard let chatGUID = payload["chatGuid"]?.stringValue, !chatGUID.isEmpty else {
      throw ServiceStartupError.unavailable("the scheduled payload has no chatGuid")
    }
    let interfaces = try await host.requireInterfaces()
    logger.debug(
      "Sending scheduled message",
      metadata: [
        "id": .stringConvertible(record.id ?? 0),
        "chat": .string(Redaction.chatGUID(chatGUID)),
      ])

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
  /// Counted from the series' FIRST date, not from the occurrence that just fired. The
  /// difference is the whole reason `firstScheduledFor` exists: a monthly message made for
  /// the 31st fires on February 29 because February has no 31st, and one that counted a
  /// month on from that would fire on March 29. Counted from January 31, March's occurrence
  /// is the 31st again. `Calendar` clamps a missing day to the month's last day, which is
  /// what a person means by "the 31st" in February.
  ///
  /// Advanced past `now` rather than by a single interval: a server that was off for a
  /// week must not wake up and fire seven days of a daily schedule one tick apart. The
  /// count starts from an estimate rather than one, so a series that has been running for
  /// years is not walked an hour at a time.
  ///
  /// `calendar` is the Mac's own by default, because that is the clock the person set the
  /// time by. A test passes a fixed one.
  static func nextOccurrence(
    after record: ScheduledMessage,
    from now: Date,
    calendar: Calendar = .current
  ) -> Date? {
    guard let blob = record.schedule,
      let schedule = try? JSONValue.parse(blob),
      schedule["type"]?.stringValue == "recurring",
      let raw = schedule["intervalType"]?.stringValue,
      let interval = RecurrenceInterval(rawValue: raw)
    else { return nil }

    let multiplier = max(1, schedule["interval"]?.intValue ?? 1)
    let anchor = record.firstScheduledFor ?? record.scheduledFor
    // After the occurrence that just fired as well as after now: with a clock that has
    // gone backwards, "the next one" is still the one after this one.
    let floor = max(now, record.scheduledFor)

    let elapsed = max(0, floor.timeIntervalSince(anchor))
    var steps = max(1, Int(elapsed / (interval.longestSeconds * Double(multiplier))))
    while true {
      guard
        let candidate = calendar.date(
          byAdding: interval.component, value: steps * multiplier, to: anchor)
      else { return nil }
      if candidate > floor { return candidate }
      steps += 1
    }
  }
}
