//  ScheduleRecurrence
//  How often a scheduled message repeats.
//
//  Shared by the composer, which offers it, and the list, which shows it. It lived inside
//  the composer as a private `Repeats`, so the list had nothing to render a stored schedule
//  with and printed the WIRE word instead, "every 2 × daily", where the composer's own
//  picker says "Daily". Two spellings of one vocabulary, and the one people saw afterwards
//  was the one nobody wrote.
//
//  Not a View, so the wire mapping can be asserted from a test; see `ScheduleRecurrenceTests`.

/// No raw value: the case is the identity, the title is a label that can be reworded, and
/// the wire spelling is its own property.
enum ScheduleRecurrence: CaseIterable, Identifiable, Hashable {
  case never, hourly, daily, weekly, monthly, yearly

  var id: Self { self }

  /// What the picker shows. Free to reword.
  var title: String {
    switch self {
    case .never: "Never"
    case .hourly: "Hourly"
    case .daily: "Daily"
    case .weekly: "Weekly"
    case .monthly: "Monthly"
    case .yearly: "Yearly"
    }
  }

  /// The period one interval covers, as a noun: "how many DAYS between sends".
  var period: String? {
    switch self {
    case .never: nil
    case .hourly: "hour"
    case .daily: "day"
    case .weekly: "week"
    case .monthly: "month"
    case .yearly: "year"
    }
  }

  /// The `intervalType` of `POST /api/v1/message/schedule`: the v1 wire vocabulary, which
  /// shipped clients and the reference's `ScheduledMessagesService` match on.
  ///
  /// FROZEN: a spelling here is a contract, and it is deliberately not derived from the case
  /// name so that renaming a case cannot change what goes over the wire.
  var intervalType: String? {
    switch self {
    case .never: nil
    case .hourly: "hourly"
    case .daily: "daily"
    case .weekly: "weekly"
    case .monthly: "monthly"
    case .yearly: "yearly"
    }
  }

  /// Reads a stored schedule back. Nil for a spelling this build does not know, which the
  /// list renders as nothing rather than as a wrong guess.
  init?(intervalType: String) {
    guard
      let match = Self.allCases.first(where: { $0.intervalType == intervalType })
    else { return nil }
    self = match
  }

  /// How a row in the list reads: "daily", or "every 3 days".
  ///
  /// The singular interval keeps the adverb, because "every 1 day" is not how anyone says
  /// it and the picker that set it said "Daily".
  func summary(every interval: Int) -> String? {
    guard let period else { return nil }
    return interval <= 1 ? title.lowercased() : "every \(interval.counted(period))"
  }
}
