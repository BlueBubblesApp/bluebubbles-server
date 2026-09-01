//  WireDate
//  ISO 8601 on the wire, for the responses that return a TypeORM ENTITY.
//
//  There are two date conventions on this API and they are easy to conflate, which has now
//  cost three separate bugs. The rule that separates them:
//
//    - **Epoch milliseconds** for the SERIALIZERS — `message.dateCreated`, `chat` timestamps,
//      everything the reference converts by hand with `.getTime()`. This is the rule the
//      compatibility contract states, and it covers the great majority of dates.
//    - **ISO 8601 strings** for a route that returns a TypeORM entity whose column is typed
//      `Date`. Nothing converts those: `JSON.stringify` renders a JS `Date` as ISO. That is
//      `alert.created`/`updated`, `scheduled_message.scheduledFor`/`sentAt`/`created`, and the
//      dates found inside a decoded property-list blob.
//
//  All three were emitting epoch milliseconds, measured against a live Electron server. The
//  contract's general rule had been generalised one step too far.
//
//  Note the asymmetry on scheduled messages, which is the reference's and not ours: the
//  REQUEST takes epoch milliseconds (`scheduledFor: "numeric|required"`) and the RESPONSE
//  returns ISO, because `EpochDateTransformer` converts on the way into the database and the
//  entity is a `Date` on the way out.

import Foundation

public enum WireDate {

  /// `JSON.stringify(new Date())`'s format: UTC, milliseconds, `Z`.
  ///
  /// Built per call rather than held in a `static let`: `ISO8601DateFormatter` is not
  /// `Sendable`, and a shared mutable one is the classic date-formatting data race. These
  /// responses carry a handful of dates, so the allocation is not worth defending against.
  ///
  /// UTC and the option set are explicit — a formatter that takes its timezone from the host
  /// produces a different string on a Mac set to another region, which is how a date format
  /// passes every test here and fails at a user's.
  public static func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }

  /// Reads one back. Tolerates a missing fractional-seconds part, because the reference's
  /// own dates carry `.000` only when the underlying column has second granularity — and a
  /// strict parser configured for milliseconds rejects a string without them.
  public static func parse(_ string: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: string) { return date }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
  }
}
