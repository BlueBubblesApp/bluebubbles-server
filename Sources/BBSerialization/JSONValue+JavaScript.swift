//  JSONValue+JavaScript
//  The two questions the reference asks of a request value in JavaScript's own terms.
//
//  The reference's checks are written as `!payload[key]` and `typeof x === "number"`, and
//  their answers differ from Swift's `!= nil` and from `intValue` in ways a client can
//  reach: an empty `chatGuid` is missing, an `interval` of `0` is absent rather than out of
//  range, and `3600.0` is as much a number as `3600`. Each was transcribed separately where
//  it was needed, and two transcriptions of the same rule disagree the first time one is
//  corrected.

import BBCore
import Foundation

extension JSONValue {

  /// JavaScript truthiness. `false`, `0`, `NaN`, `""` and `null` are falsy; everything else
  /// is truthy, an empty array or object included.
  public var isTruthy: Bool {
    switch self {
    case .null: false
    case .bool(let value): value
    case .int(let value): value != 0
    case .int64(let value): value != 0
    case .double(let value): value != 0 && !value.isNaN
    case .string(let value): !value.isEmpty
    case .array, .object: true
    }
  }

  /// The value as a `Double` if it is a JSON number, whichever case it was decoded into;
  /// nil for anything else, a numeric STRING included. `typeof x === "number"`.
  ///
  /// `JSONValue` keeps `.int`, `.int64` and `.double` apart, and a client sending `3600`
  /// and one sending `3600.0` mean the same thing: reading only one case is how a valid
  /// request becomes a 400.
  public var numberValue: Double? {
    switch self {
    case .int(let value): Double(value)
    case .int64(let value): Double(value)
    case .double(let value): value
    default: nil
    }
  }
}

extension Optional where Wrapped == JSONValue {

  /// An absent key is `undefined`, which is falsy.
  public var isTruthy: Bool { self?.isTruthy ?? false }
}
