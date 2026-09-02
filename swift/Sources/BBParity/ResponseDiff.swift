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
    /// One side had no elements, so what is inside them was never checked. A gap in
    /// coverage, reported rather than scored as agreement.
    case notCompared = "unverified"
  }

  public let kind: Kind
  public let path: String
  public let detail: String

  public var description: String {
    detail.isEmpty ? "\(kind.rawValue) at \(path)" : "\(kind.rawValue) at \(path): \(detail)"
  }
}

/// How hard the diff compares.
///
/// `.strict` is the original and the one that means the most: two servers, one Mac, one
/// database, so every value should agree and any that does not is a finding.
///
/// `.shape` exists because the recorded corpus cannot be replayed that way. The fixtures were
/// captured against a real Mac holding real conversations; a replay runs against a synthetic
/// `chat.db` with seven messages in it. Every count, GUID, address and body text differs by
/// construction, and comparing them would produce a wall of noise with the real findings
/// buried in it.
///
/// So `.shape` drops scalar VALUES and keeps everything that is actually the contract: which
/// keys exist, what type each one is, and the handful of strings that are themselves the
/// contract — the envelope's `status` and `message`, and `error.type`. That is the whole of
/// what a client parses before it looks at anyone's data, and it is where every divergence
/// found so far has lived.
public enum DiffMode: Sendable {
  case strict
  case shape

  /// Keys whose literal value is part of the contract even in `.shape`.
  ///
  /// `message` is here because about forty routes carry their own string and this server
  /// answered "Success" for all of them until the strings were transcribed; `error.type` is
  /// here because the status/error-type pairing is one of the stated compatibility
  /// invariants. Both are literals a client branches on, not data.
  static let contractualScalars: Set<String> = ["status", "message", "type"]
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
    mode: DiffMode = .strict,
    ignoring ignored: Set<String> = volatileFields,
    accepting accepted: [String: String] = acceptedDifferences
  ) -> [Difference] {
    var differences: [Difference] = []
    let expectedKeys = Set(expected.keys)
    let actualKeys = Set(actual.keys)

    // MISSING is the one that matters. The requirement this harness exists to enforce is
    // that every field the reference sends is present here; an extra field of ours is
    // tolerable, and clients ignore what they do not know.
    for key in expectedKeys.subtracting(actualKeys).sorted() {
      differences.append(.init(kind: .missingKey, path: "\(path)\(key)", detail: ""))
    }
    // UNEXPECTED is still reported, because one-way the diff stops being a drift check: a
    // field that REPLACED another, or an internal value that leaked into a response, both
    // look like an addition plus a removal and only the removal half would be caught.
    //
    // An addition we CHOSE is declared in `acceptedDifferences` and skipped here. It was
    // not skipped here before, so declaring an added key did nothing at all — the entry
    // silenced the value check for a key the loop above had already failed on.
    for key in actualKeys.subtracting(expectedKeys).sorted() where accepted[key] == nil {
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
            mode: mode, ignoring: ignored, accepting: accepted
          ))

      case (let left as [Any], let right as [Any]):
        // The length is reported and then the elements are compared ANYWAY.
        //
        // It used to be `else`, and that one keyword cost six findings on one route:
        // `contact` reported "length at data: 552 vs 587" and stopped, so an added key,
        // two dropped keys, a missing nested `id` and a null `displayName` all sat behind
        // a number that read like an environment difference. Two servers holding
        // identical data is the rare case, not the common one — a length mismatch must
        // never suppress what is inside the array.
        if left.count != right.count, mode == .strict {
          differences.append(
            .init(
              kind: .arrayLength, path: childPath,
              detail: "\(left.count) vs \(right.count)"
            ))
        }
        // One side empty means the element shape is UNVERIFIED, not equal. Reported as
        // its own kind so a replay can count what it could not see instead of scoring it
        // as a pass — the failure this whole harness exists to prevent is a check that
        // silently stops checking.
        if left.isEmpty != right.isEmpty {
          differences.append(
            .init(
              kind: .notCompared, path: childPath,
              detail: left.isEmpty
                ? "reference is empty; \(right.count) here" : "\(left.count) expected; empty here"
            ))
        }
        for (index, pair) in zip(left, right).enumerated() {
          if let leftObject = pair.0 as? [String: Any],
            let rightObject = pair.1 as? [String: Any]
          {
            differences.append(
              contentsOf: compare(
                expected: leftObject, actual: rightObject,
                path: "\(childPath)[\(index)].",
                mode: mode, ignoring: ignored, accepting: accepted
              ))
          } else if let difference = scalarDifference(
            pair.0, pair.1, at: "\(childPath)[\(index)]", mode: mode
          ) {
            differences.append(difference)
          }
        }

      default:
        if let difference = scalarDifference(lhs, rhs, at: childPath, mode: mode, key: key) {
          differences.append(difference)
        }
      }
    }

    return differences
  }

  /// One scalar against another, under the active mode.
  ///
  /// Type before value: "number vs string" is a more useful report than `1 vs "1"`, and the
  /// two are genuinely different breaks.
  ///
  /// In `.shape` the value check is dropped for everything but the contract literals, and the
  /// TYPE check is dropped when either side is null. That second exemption is not laxity —
  /// almost every entity field in this API is nullable (`subject`, `groupTitle`,
  /// `associatedMessageType`), so whether one is null is a fact about whose message was read,
  /// not about the response's shape. Asserting it against a different database would fail on
  /// every route while proving nothing.
  static func scalarDifference(
    _ lhs: Any, _ rhs: Any, at path: String, mode: DiffMode, key: String? = nil
  ) -> Difference? {
    let nullEither = lhs is NSNull || rhs is NSNull

    if !sameShape(lhs, rhs) {
      if mode == .shape, nullEither { return nil }
      return .init(
        kind: .typeDiffers, path: path, detail: "\(typeName(lhs)) vs \(typeName(rhs))"
      )
    }

    if mode == .shape {
      // The literals a client branches on, and nothing else.
      guard let key, DiffMode.contractualScalars.contains(key) else { return nil }
    }

    guard !equalScalars(lhs, rhs) else { return nil }
    return .init(kind: .valueDiffers, path: path, detail: "\(lhs) vs \(rhs)")
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
