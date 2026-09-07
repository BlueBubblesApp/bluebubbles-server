//  OrderedJSON
//  A JSON value that remembers the order its keys were written in.
//
//  `JSONValue` cannot be used for this. Its `object` case is a `[String: JSONValue]`, and
//  `serialize()` says so itself: key order is arbitrary and varies BETWEEN PROCESSES. That is
//  fine on the wire, where every comparison is structural — and fatal here, because the
//  generated document is committed and diffed in CI. A spec emitted through `JSONValue` would
//  reorder its keys on a rerun and report a diff for a table nobody touched, which trains
//  everyone to ignore the check that is the whole point of committing it.
//
//  So: an ordered representation and a hand-written serializer. Byte-stable output for the
//  same input, which is what makes `git diff --exit-code` a real assertion.
//
//  See `.claude/docs/api.md`.

import Foundation

public indirect enum OrderedJSON: Sendable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([OrderedJSON])
  /// Insertion-ordered. A dictionary here would reintroduce exactly the problem this type
  /// exists to solve.
  case object([(key: String, value: OrderedJSON)])

  /// Builds an object, dropping entries whose value is nil.
  ///
  /// Almost every OpenAPI field is optional, and the alternative is a `var` plus a wall of
  /// `if let` at each of the ~30 construction sites.
  public static func obj(_ pairs: [(String, OrderedJSON?)]) -> OrderedJSON {
    .object(pairs.compactMap { key, value in value.map { (key: key, value: $0) } })
  }
}

extension OrderedJSON {

  /// Pretty-printed with two-space indentation, and a trailing newline.
  ///
  /// Always pretty: this file is read by people in review, and a diff on one changed route
  /// should be one changed line rather than the whole document.
  public func serialized() -> String {
    var out = ""
    write(into: &out, depth: 0)
    out.append("\n")
    return out
  }

  private func write(into out: inout String, depth: Int) {
    let pad = String(repeating: " ", count: depth * 2)
    let inner = String(repeating: " ", count: (depth + 1) * 2)

    switch self {
    case .null:
      out += "null"
    case .bool(let value):
      out += value ? "true" : "false"
    case .int(let value):
      out += String(value)
    case .double(let value):
      // A whole double must not print as `3.0` one run and `3` the next. Foundation's
      // default description is stable, but an integral value is written as an integer
      // so the document reads the way a hand-written spec would.
      if value == value.rounded(), abs(value) < 1e15 {
        out += String(Int(value))
      } else {
        out += String(value)
      }
    case .string(let value):
      out += Self.quote(value)

    case .array(let elements):
      guard !elements.isEmpty else {
        out += "[]"
        return
      }
      out += "[\n"
      for (index, element) in elements.enumerated() {
        out += inner
        element.write(into: &out, depth: depth + 1)
        out += index == elements.count - 1 ? "\n" : ",\n"
      }
      out += pad + "]"

    case .object(let pairs):
      guard !pairs.isEmpty else {
        out += "{}"
        return
      }
      out += "{\n"
      for (index, pair) in pairs.enumerated() {
        out += inner + Self.quote(pair.key) + ": "
        pair.value.write(into: &out, depth: depth + 1)
        out += index == pairs.count - 1 ? "\n" : ",\n"
      }
      out += pad + "}"
    }
  }

  /// RFC 8259 string escaping.
  ///
  /// Non-ASCII is emitted as raw UTF-8 rather than `\u` escapes — valid JSON, and it keeps
  /// the document readable. Only what the grammar requires is escaped.
  public static func quote(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }
}
