//  ResponseDiff
//  The strict two-way diff, shared by the fixture harness and the live side-by-side runner.
//
//  Extracted into a library because Phase 12 needs it twice: `Tests/CompatibilityTests` replays
//  recorded fixtures, and `bb-parity` drives two live servers. Two copies of a comparison
//  this specific would drift, and the drift would be invisible — a live run reporting "no
//  differences" because its copy stopped checking something the fixture copy still checks.
//
//  **Strict in both directions.** An added key fails exactly like a missing one. That is the
//  whole point: a field added to a response is a compatibility break, not a harmless
//  enhancement, and a one-way diff would let every one of them through.
//
//  See `.claude/docs/decisions.md`.

import Foundation

/// Fields that legitimately vary between two runs of the same request.
///
/// Compared for PRESENCE and TYPE, not value. A timestamp that differs between two servers
/// asked the same question at different moments is not a compatibility break; a timestamp
/// that vanished, or turned into a string, is.
/// Fields compared by PRESENCE and TYPE rather than by value.
///
/// Keep this list as short as it can be. Every entry is a value nobody is checking, and the
/// blind spot is real: `os_version` sat here and hid the fact that this server was sending
/// `"Version 26.5.2 (Build 25F84)"` where the reference sends `"26.5.2"`. Both are strings, so
/// the diff was satisfied. It was found by reading a response by hand instead.
///
/// The test for membership is "could these two servers legitimately disagree while both being
/// correct?" — and the parity harness runs BOTH SERVERS ON ONE MAC, which rules out most
/// candidates. `computer_id`, `os_version` and the interface lists describe the machine, so
/// they must match exactly; they were listed here and are not any more.
public let volatileFields: Set<String> = [
  // Timestamps: the two servers read different rows and answer at different instants.
  "created", "updated", "dateCreated", "dateRead", "dateDelivered", "datePlayed",
  "dateEdited", "dateRetracted", "timeExpressiveSendPlayed",
  // A live sntp measurement. Two consecutive calls disagree.
  "macos_time_sync",
  // Genuinely different by construction: a dev build against a release, and two servers
  // deliberately configured onto different ports and connection methods.
  "server_version", "proxy_service", "server_address",
]

/// Differences that are REAL, understood, and deliberate.
///
/// Separate from `volatileFields` on purpose. Volatile means "nobody can predict this value";
/// this means "we know exactly what the difference is and we chose it". Collapsing the two
/// would let a decision hide among the noise — which is how `os_version` sent a
/// human-readable build string for months.
///
/// Each entry has to say what the difference IS, so that reading this list is enough to judge
/// whether the decision still holds.
public let acceptedDifferences: [String: String] = [
  // The reference publishes link-local IPv6 (`fe80::…`) because Node's `internal` flag does
  // not catch it. A bare link-local address cannot be dialled without a zone index, and this
  // field feeds the "how do I reach my server" setup screen, so publishing them is noise a
  // client cannot act on. Confirmed as a deliberate keep.
  "local_ipv6s": "link-local addresses are dropped; the reference publishes them"
]

public struct Difference: Sendable, Equatable, CustomStringConvertible {
  public enum Kind: String, Sendable {
    case missingKey = "missing"
    case unexpectedKey = "unexpected"
    case valueDiffers = "value"
    case typeDiffers = "type"
    case arrayLength = "length"
  }

  public let kind: Kind
  public let path: String
  public let detail: String

  public var description: String {
    detail.isEmpty ? "\(kind.rawValue) at \(path)" : "\(kind.rawValue) at \(path): \(detail)"
  }
}

public enum ResponseDiff {

  /// Compares two decoded JSON objects.
  ///
  /// - Parameter expected: The reference — a recorded fixture, or the Node server's answer.
  /// - Parameter actual: The Swift server's answer.
  public static func compare(
    expected: [String: Any],
    actual: [String: Any],
    path: String = "",
    ignoring ignored: Set<String> = volatileFields,
    accepting accepted: [String: String] = acceptedDifferences
  ) -> [Difference] {
    var differences: [Difference] = []
    let expectedKeys = Set(expected.keys)
    let actualKeys = Set(actual.keys)

    for key in expectedKeys.subtracting(actualKeys).sorted() {
      differences.append(.init(kind: .missingKey, path: "\(path)\(key)", detail: ""))
    }
    for key in actualKeys.subtracting(expectedKeys).sorted() {
      differences.append(.init(kind: .unexpectedKey, path: "\(path)\(key)", detail: ""))
    }

    for key in expectedKeys.intersection(actualKeys).sorted() {
      let childPath = "\(path)\(key)"
      let lhs = expected[key]!
      let rhs = actual[key]!

      // A difference we already understand and chose. Skipped entirely rather than
      // type-checked: the shapes legitimately differ (an empty array against a
      // populated one), which is the whole point of the entry.
      if accepted[key] != nil { continue }

      if ignored.contains(key) {
        // Still type-checked. A volatile field that changed from a number to a
        // string, or to null, IS a break — only its value is allowed to move.
        if !sameShape(lhs, rhs) {
          differences.append(
            .init(
              kind: .typeDiffers, path: childPath,
              detail: "\(typeName(lhs)) vs \(typeName(rhs))"
            ))
        }
        continue
      }

      switch (lhs, rhs) {
      case (let left as [String: Any], let right as [String: Any]):
        differences.append(
          contentsOf: compare(
            expected: left, actual: right, path: "\(childPath).",
            ignoring: ignored, accepting: accepted
          ))

      case (let left as [Any], let right as [Any]):
        if left.count != right.count {
          differences.append(
            .init(
              kind: .arrayLength, path: childPath,
              detail: "\(left.count) vs \(right.count)"
            ))
        } else {
          for (index, pair) in zip(left, right).enumerated() {
            if let leftObject = pair.0 as? [String: Any],
              let rightObject = pair.1 as? [String: Any]
            {
              differences.append(
                contentsOf: compare(
                  expected: leftObject, actual: rightObject,
                  path: "\(childPath)[\(index)].",
                  ignoring: ignored, accepting: accepted
                ))
            } else if !equalScalars(pair.0, pair.1) {
              differences.append(
                .init(
                  kind: .valueDiffers, path: "\(childPath)[\(index)]",
                  detail: "\(pair.0) vs \(pair.1)"
                ))
            }
          }
        }

      default:
        // Type before value. "number vs string" is a more useful report than
        // "1 vs \"1\"", and the two are genuinely different breaks.
        if !sameShape(lhs, rhs) {
          differences.append(
            .init(
              kind: .typeDiffers, path: childPath,
              detail: "\(typeName(lhs)) vs \(typeName(rhs))"
            ))
        } else if !equalScalars(lhs, rhs) {
          differences.append(
            .init(
              kind: .valueDiffers, path: childPath, detail: "\(lhs) vs \(rhs)"
            ))
        }
      }
    }

    return differences
  }

  /// Whether two values are the same JSON kind.
  ///
  /// Bool is checked before number: `NSNumber` erases Bool, so `true` and `1` are the same
  /// object type to Foundation, and treating them as equal would hide a real break — a
  /// client parsing `true` from a field that started returning `1` fails.
  static func sameShape(_ lhs: Any, _ rhs: Any) -> Bool {
    typeName(lhs) == typeName(rhs)
  }

  static func typeName(_ value: Any) -> String {
    switch value {
    case is NSNull: return "null"
    case let number as NSNumber:
      return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
    case is String: return "string"
    case is [Any]: return "array"
    case is [String: Any]: return "object"
    default: return String(describing: type(of: value))
    }
  }

  static func equalScalars(_ lhs: Any, _ rhs: Any) -> Bool {
    switch (lhs, rhs) {
    case (is NSNull, is NSNull):
      return true
    case (let left as NSNumber, let right as NSNumber):
      return left == right
    case (let left as String, let right as String):
      return left == right
    default:
      return String(describing: lhs) == String(describing: rhs)
    }
  }
}
