//  MessageFlow
//  Messages sent and received per day, by service and by hour of the week, over a range of
//  local days.
//
//  The repository counts between boundaries it is given (see
//  `MessageRepository+Activity.swift`); this is where the boundaries come from and where the
//  counts are folded into what a chart draws. Both halves are pure and take the calendar and
//  `now` as arguments, so a test can state a day that crosses a daylight-saving change and
//  what it expects of it.
//
//  Not on the wire. Nothing here is a v1 shape, and nothing a client reads depends on it.

import BBIMessage
import Foundation

public struct MessageFlow: Sendable, Equatable {

  public struct Day: Sendable, Equatable, Identifiable {
    public let start: Date
    public var sent = 0
    public var received = 0
    /// Keyed by `message.service`: `iMessage`, `SMS`, `RCS`. A row with no service is keyed
    /// by the empty string rather than dropped, so the services always add up to the day.
    public var byService: [String: Int] = [:]
    public var total: Int { sent + received }
    public var id: Date { start }

    public init(start: Date, sent: Int = 0, received: Int = 0, byService: [String: Int] = [:]) {
      self.start = start
      self.sent = sent
      self.received = received
      self.byService = byService
    }
  }

  /// Oldest first, one per day in the range, including the days nothing happened.
  public let days: [Day]
  /// `[weekday][hour]`: weekday 0 is the calendar's Sunday, hour is local, `0..<24`.
  public let heatmap: [[Int]]

  public var sent: Int { days.reduce(0) { $0 + $1.sent } }
  public var received: Int { days.reduce(0) { $0 + $1.received } }
  public var total: Int { sent + received }

  public var byService: [String: Int] {
    days.reduce(into: [:]) { result, day in
      for (service, count) in day.byService { result[service, default: 0] += count }
    }
  }

  public init(days: [Day], heatmap: [[Int]]) {
    self.days = days
    self.heatmap = heatmap
  }

  /// The last `count` local days, ending with the one `now` falls in (which is partial).
  ///
  /// Each day's end is the NEXT day's start rather than `start + 86,400`, which is what
  /// makes a 23- or 25-hour day around a clock change the right length.
  public static func days(
    endingAt now: Date, count: Int, calendar: Calendar
  ) -> [MessageRepository.ActivityDay] {
    guard count > 0 else { return [] }
    let today = calendar.startOfDay(for: now)
    return (0..<count).reversed().compactMap { back in
      guard let start = calendar.date(byAdding: .day, value: -back, to: today),
        let end = calendar.date(byAdding: .day, value: 1, to: start)
      else { return nil }
      return MessageRepository.ActivityDay(
        start: start, end: end,
        utcOffset: calendar.timeZone.secondsFromGMT(for: start))
    }
  }

  /// Folds the repository's cells into days and a heatmap.
  public static func aggregate(
    _ cells: [MessageRepository.ActivityCell],
    days: [MessageRepository.ActivityDay],
    calendar: Calendar
  ) -> MessageFlow {
    var result = days.map { Day(start: $0.start) }
    var heatmap = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    let weekdays = days.map { calendar.component(.weekday, from: $0.start) - 1 }
    for cell in cells where result.indices.contains(cell.day) {
      if cell.isFromMe {
        result[cell.day].sent += cell.count
      } else {
        result[cell.day].received += cell.count
      }
      result[cell.day].byService[cell.service, default: 0] += cell.count
      if (0..<24).contains(cell.hour), (0..<7).contains(weekdays[cell.day]) {
        heatmap[weekdays[cell.day]][cell.hour] += cell.count
      }
    }
    return MessageFlow(days: result, heatmap: heatmap)
  }
}

extension MessageInterface {

  /// Messages per local day over the last `days` days, ending today.
  public func flow(
    days count: Int, now: Date = Date(), calendar: Calendar = .current
  ) async throws -> MessageFlow {
    let days = MessageFlow.days(endingAt: now, count: count, calendar: calendar)
    let cells = try await repository.messageActivity(days: days)
    return MessageFlow.aggregate(cells, days: days, calendar: calendar)
  }

  /// The busiest conversations over the same window `flow` covers.
  public func busiestChats(
    days count: Int, limit: Int, now: Date = Date(), calendar: Calendar = .current
  ) async throws -> [MessageRepository.ChatActivity] {
    let days = MessageFlow.days(endingAt: now, count: count, calendar: calendar)
    guard let first = days.first, let last = days.last else { return [] }
    return try await repository.busiestChats(from: first.start, to: last.end, limit: limit)
  }

  /// The conversations that began inside the same window `flow` covers, newest first.
  public func newChats(
    days count: Int, limit: Int, now: Date = Date(), calendar: Calendar = .current
  ) async throws -> [MessageRepository.NewChat] {
    let days = MessageFlow.days(endingAt: now, count: count, calendar: calendar)
    guard let first = days.first, let last = days.last else { return [] }
    return try await repository.newChats(from: first.start, to: last.end, limit: limit)
  }
}
