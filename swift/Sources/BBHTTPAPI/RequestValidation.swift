//  RequestValidation
//  The v1 request-validation layer: rejects what the reference rejects, and nothing else.
//
//  WHY THIS EXISTS
//  The reference runs validatorjs rule sets per route (`validators/*.ts`) and answers a 400
//  whose `error.message` is the generated sentence. This server had none of it, so a field of
//  the wrong type read as absent and the route's default quietly applied:
//  `POST /message/query` with `{"limit": "not-a-number"}` is a 400 there and was a 200 here,
//  with a `total` counting the whole database and no way for the client to tell. That is the
//  same shape as the `where`-parameter omission, and it is the last known one on the v1 wire.
//
//  THE DIRECTION OF RISK IS ONE-WAY, AND IT IS THE WHOLE DESIGN CONSTRAINT
//  Every other change in this project can be too strict or too lax. This one can only break
//  clients by being too STRICT: a request that used to succeed and now 400s. A rule that is
//  too lax merely preserves today's behaviour. So where the reference's semantics are
//  surprising, they are reproduced exactly rather than tidied, and where a reproduction would
//  be a guess, the field is left unvalidated. `ValidationRules` records each such decision.
//
//  This is NOT a port of validatorjs. Per `.claude/docs/decisions.md`, the reference
//  constrains the v1 WIRE and not how this server is built: the rules here are typed Swift
//  values checked by a `switch`, with no rule-string parser and no registry. What is
//  reproduced is the OUTPUT — which inputs are refused, and the exact sentence — because both
//  are observable. Everything else is ours.
//
//  THE SURPRISES, each measured from `node_modules/validatorjs/src` rather than assumed
//
//    1. A non-implicit rule does not run at all unless the value is "required-passing" or is
//       an array (`validator.js:_isValidatable`). So `""`, `"   "`, `null` and an absent key
//       satisfy `string`, `numeric`, `boolean`, `in` and `min`/`max` by never reaching them.
//       This is why `{"limit": ""}` is a 200 in the reference, and it has to stay one.
//    2. `numeric` is `Number(val)` coercion, not a type check (`rules.js:numeric`). `"25"`
//       passes, which is the property `RequestValues`' leniency was written for and the one
//       most likely to be broken by a "sensible" reimplementation. Booleans are excluded
//       explicitly; everything else that coerces is accepted.
//    3. `in` passes for any FALSY value (`rules.js:in` opens with `if (val)`). `sort: ""`
//       satisfies `in:ASC,DESC`. Comparison is by `String(val)` when the list holds strings.
//    4. `required` rejects on `String(val)` with ALL whitespace stripped being empty, so an
//       empty ARRAY fails `required` (`String([]) === ""`) while `[1]` passes. `0` and
//       `false` both pass.
//    5. `min`/`max` measure `getSize()`, which is the NUMBER for a numeric field, the LENGTH
//       for an array, and the CHARACTER COUNT otherwise (`rules.js:getSize`). One rule, three
//       meanings, and the message template changes with it.
//    6. Only the FIRST failure is reported, taken in declaration order: fields in the order
//       the reference's rule object lists them, and within a field, its rules in order
//       (`validators/index.ts:getFirstError`). Order here is therefore part of the contract,
//       which is why these are ordered arrays and not dictionaries.
//
//  See `.claude/docs/api.md` and `ValidationRules.swift` for the per-route table.

import BBSerialization
import Foundation

// MARK: - Rules

/// One check, as a typed value rather than a parsed rule string.
public enum ValidationRule: Sendable, Equatable {
  /// Present, non-null, and not whitespace-only. Implicit: runs even on an absent value.
  case required
  /// Merely not absent. `null` satisfies it. Implicit, and the reason `message` on
  /// `POST /message/text` may be explicitly null but may not be omitted.
  case present
  case string
  /// Coerces, per JS `Number()`. Not a type check. See surprise 2 above.
  case numeric
  case boolean
  case array
  /// The reference's custom `json-object` rule: a non-null object.
  case jsonObject
  /// Membership. A falsy value passes; see surprise 3.
  case inList([String])
  case min(Double)
  case max(Double)

  /// Implicit rules run against an absent value; every other rule is skipped for one.
  var isImplicit: Bool {
    switch self {
    case .required, .present: true
    default: false
    }
  }

  /// `validator.js:numericRules`. Drives both `getSize` and the min/max message template.
  var isNumericRule: Bool {
    if case .numeric = self { return true }
    return false
  }
}

/// One field's rules, in the order the reference declares them.
public struct FieldValidation: Sendable, Equatable {
  public let field: String
  public let rules: [ValidationRule]

  public init(_ field: String, _ rules: [ValidationRule]) {
    self.field = field
    self.rules = rules
  }

  var hasNumericRule: Bool { rules.contains(where: \.isNumericRule) }
}

/// Which part of the request a rule set reads.
///
/// The reference passes `ctx.request.body`, `ctx.request.query` or `ctx.params` explicitly per
/// validator, and the three are different shapes: a body is parsed JSON with real types, while
/// query and path values are always strings. That difference is load-bearing — `after=5` in a
/// query is the string `"5"`, which passes `numeric` by coercion and measures as the number 5
/// under `min` — so the source travels with the rule set rather than being inferred.
public enum ValidationSource: Sendable, Equatable {
  case body
  case query
  case path
}

public struct ValidationRuleSet: Sendable, Equatable {
  public let source: ValidationSource
  public let fields: [FieldValidation]

  public init(_ source: ValidationSource, _ fields: [FieldValidation]) {
    self.source = source
    self.fields = fields
  }
}

// MARK: - The check

public enum RequestValidator {

  /// Runs a rule set, throwing the reference's 400 on the first failure.
  ///
  /// `input` is an object; a body that parsed to something else is treated as empty, which
  /// matches the reference (validatorjs flattens a non-object to no attributes, so every
  /// non-implicit rule is skipped and only `required`/`present` can fail).
  public static func validate(_ input: JSONValue, against ruleSet: ValidationRuleSet) throws {
    let object: [String: JSONValue]
    if case .object(let values) = input {
      object = values
    } else {
      object = [:]
    }

    for field in ruleSet.fields {
      // Wildcard fields (`where.*.statement`) expand against the data, one attribute per
      // element, exactly as `_parsedRulesRecurse` does. A wildcard whose parent is absent
      // or not an array expands to nothing and is skipped entirely.
      for (path, value) in expand(field.field, in: object) {
        for rule in field.rules {
          guard isValidatable(rule, value) else { continue }
          guard !passes(rule, value, hasNumericRule: field.hasNumericRule) else { continue }
          throw BadRequest(
            message(for: rule, attribute: path, value: value, hasNumericRule: field.hasNumericRule)
          )
        }
      }
    }
  }

  // MARK: Expansion

  /// Resolves a field path to the attribute/value pairs the reference would check.
  ///
  /// Returns exactly one pair for an ordinary field (with a `nil` value when absent, which is
  /// what the implicit rules need to see). A `*` segment expands over the array at its parent
  /// path, numbering the attributes as the reference's messages do (`where.0.statement`).
  private static func expand(
    _ path: String, in object: [String: JSONValue]
  ) -> [(String, JSONValue?)] {
    guard path.contains("*") else {
      return [(path, lookup(path, in: object))]
    }

    let segments = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard let wildcard = segments.firstIndex(of: "*") else {
      return [(path, lookup(path, in: object))]
    }

    let parentPath = segments[..<wildcard].joined(separator: ".")
    guard case .array(let elements)? = lookup(parentPath, in: object) else { return [] }

    return elements.indices.flatMap { index -> [(String, JSONValue?)] in
      var resolved = segments
      resolved[wildcard] = String(index)
      return expand(resolved.joined(separator: "."), in: object)
    }
  }

  /// Dot-path lookup. `nil` means absent, which is distinct from `.null`.
  private static func lookup(_ path: String, in object: [String: JSONValue]) -> JSONValue? {
    // A literal key wins over a path interpretation, matching `_objectPath`'s
    // `hasOwnProperty` check: a body with a key that literally contains a dot is read as
    // that key rather than walked.
    if let direct = object[path] { return direct }

    var current: JSONValue = .object(object)
    for segment in path.split(separator: ".") {
      switch current {
      case .object(let values):
        guard let next = values[String(segment)] else { return nil }
        current = next
      case .array(let elements):
        guard let index = Int(segment), elements.indices.contains(index) else { return nil }
        current = elements[index]
      default:
        return nil
      }
    }
    return current
  }

  // MARK: Rule evaluation

  /// `validator.js:_isValidatable`. An array is always checked; otherwise a non-implicit rule
  /// runs only when the value would satisfy `required`.
  private static func isValidatable(_ rule: ValidationRule, _ value: JSONValue?) -> Bool {
    if case .array? = value { return true }
    if rule.isImplicit { return true }
    return passesRequired(value)
  }

  private static func passes(
    _ rule: ValidationRule, _ value: JSONValue?, hasNumericRule: Bool
  ) -> Bool {
    switch rule {
    case .required:
      return passesRequired(value)

    case .present:
      return value != nil

    case .string:
      if case .string? = value { return true }
      return false

    case .numeric:
      // `typeof val !== "boolean"` is an explicit carve-out in the reference: `Number(true)`
      // is 1 and would otherwise pass.
      if case .bool? = value { return false }
      return jsNumber(value).map { !$0.isNaN } ?? false

    case .boolean:
      switch value {
      case .bool: return true
      case .int(let value): return value == 0 || value == 1
      case .int64(let value): return value == 0 || value == 1
      case .double(let value): return value == 0 || value == 1
      case .string(let value): return ["0", "1", "true", "false"].contains(value)
      default: return false
      }

    case .array:
      if case .array? = value { return true }
      return false

    case .jsonObject:
      if case .object? = value { return true }
      return false

    case .inList(let allowed):
      // Falsy passes, untouched. See surprise 3.
      guard let value, isTruthy(value) else { return true }
      if case .array(let elements) = value {
        return elements.allSatisfy { allowed.contains(jsString($0)) }
      }
      return allowed.contains(jsString(value))

    case .min(let bound):
      guard let size = size(of: value, hasNumericRule: hasNumericRule) else { return true }
      return size >= bound

    case .max(let bound):
      guard let size = size(of: value, hasNumericRule: hasNumericRule) else { return true }
      return size <= bound
    }
  }

  /// `rules.js:required` — `String(val)` with every whitespace character removed must be
  /// non-empty. Note that this makes an EMPTY ARRAY fail and `0` pass.
  private static func passesRequired(_ value: JSONValue?) -> Bool {
    guard let value, value != .null else { return false }
    return !jsString(value).filter { !$0.isWhitespace }.isEmpty
  }

  /// `rules.js:getSize`. Three meanings, picked in this order: array length, the number
  /// itself, the parsed number when the field is numeric, otherwise the character count.
  private static func size(of value: JSONValue?, hasNumericRule: Bool) -> Double? {
    guard let value else { return nil }
    switch value {
    case .array(let elements):
      return Double(elements.count)
    case .int(let value):
      return Double(value)
    case .int64(let value):
      return Double(value)
    case .double(let value):
      return value
    default:
      if hasNumericRule {
        // `parseFloat`, which is a PREFIX parse: "12abc" is 12. Distinct from `Number()`,
        // and the difference is reachable, because `numeric` runs before `min` and would
        // have refused "12abc" first only if it is also the earlier rule. Where it is not
        // (nothing in the table today), the reference measures the prefix.
        return jsParseFloat(jsString(value))
      }
      return Double(jsString(value).count)
    }
  }

  private static func isTruthy(_ value: JSONValue) -> Bool {
    switch value {
    case .null: false
    case .bool(let value): value
    case .int(let value): value != 0
    case .int64(let value): value != 0
    case .double(let value): value != 0 && !value.isNaN
    case .string(let value): !value.isEmpty
    case .array, .object: true
    }
  }

  // MARK: Messages

  /// The generated sentence, from `lang/en.js`. A client shows this string and some branch on
  /// it, so it is the contract and is transcribed verbatim.
  private static func message(
    for rule: ValidationRule, attribute: String, value: JSONValue?, hasNumericRule: Bool
  ) -> String {
    let name = attributeName(attribute)
    switch rule {
    case .required:
      return "The \(name) field is required."
    case .present:
      return "The \(name) field must be present (but can be empty)."
    case .string:
      return "The \(name) must be a string."
    case .numeric:
      return "The \(name) must be a number."
    case .boolean, .array:
      // Neither rule has an entry in `lang/en.js`, so both fall through to `def`.
      return "The \(name) attribute has errors."
    case .jsonObject:
      // The message registered alongside the custom rule in `validators/index.ts`.
      return "The \(name) must be a valid json object."
    case .inList:
      return "The selected \(name) is invalid."
    case .min(let bound):
      return isNumericContext(value, hasNumericRule: hasNumericRule)
        ? "The \(name) must be at least \(number(bound))."
        : "The \(name) must be at least \(number(bound)) characters."
    case .max(let bound):
      return isNumericContext(value, hasNumericRule: hasNumericRule)
        ? "The \(name) may not be greater than \(number(bound))."
        : "The \(name) may not be greater than \(number(bound)) characters."
    }
  }

  /// `rules.js:_getValueType` — numeric when the value IS a number or the field has a numeric
  /// rule. An array with no numeric rule renders as the "characters" wording, which reads
  /// oddly and is what ships.
  private static func isNumericContext(_ value: JSONValue?, hasNumericRule: Bool) -> Bool {
    if hasNumericRule { return true }
    switch value {
    case .int, .int64, .double: return true
    default: return false
    }
  }

  /// `attributes.js:formatter` — `_` and `[` become spaces, `]` is dropped. Dots are left
  /// alone, so a wildcard attribute renders as `where.0.statement`.
  private static func attributeName(_ attribute: String) -> String {
    String(
      attribute.map { character in
        character == "_" || character == "[" ? " " : character
      }.filter { $0 != "]" })
  }

  /// Rule parameters are substituted as written, so an integral bound has no decimal point.
  private static func number(_ value: Double) -> String {
    value == value.rounded() && value.magnitude < 1e15
      ? String(Int64(value))
      : String(value)
  }

  // MARK: JS coercion

  /// `String(val)`, for the cases `required` and `in` can reach.
  private static func jsString(_ value: JSONValue) -> String {
    switch value {
    case .null: "null"
    case .bool(let value): value ? "true" : "false"
    case .int(let value): String(value)
    case .int64(let value): String(value)
    case .double(let value): jsNumberToString(value)
    case .string(let value): value
    // `String([1,2])` is "1,2"; `String([])` is "", which is what makes an empty array fail
    // `required`.
    case .array(let elements): elements.map(jsString).joined(separator: ",")
    case .object: "[object Object]"
    }
  }

  /// JS prints an integral double without a decimal point, which matters for `in` comparisons
  /// against a list of strings.
  private static func jsNumberToString(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
    if value == value.rounded() && value.magnitude < 1e21 { return String(Int64(value)) }
    return String(value)
  }

  /// `Number(val)`. Returns nil where JS returns NaN.
  ///
  /// Deliberately permissive in the same places JS is, because every gap here is a request the
  /// reference accepts and this server would refuse.
  private static func jsNumber(_ value: JSONValue?) -> Double? {
    switch value {
    case nil: return nil
    case .null: return 0
    case .bool(let value): return value ? 1 : 0
    case .int(let value): return Double(value)
    case .int64(let value): return Double(value)
    case .double(let value): return value
    case .string(let raw): return jsNumberFromString(raw)
    case .array(let elements):
      // `Number([])` is 0 and `Number([5])` is 5, via `String()`; anything longer is NaN.
      if elements.isEmpty { return 0 }
      guard elements.count == 1 else { return nil }
      return jsNumberFromString(jsString(elements[0]))
    case .object: return nil
    }
  }

  private static func jsNumberFromString(_ raw: String) -> Double? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // `Number("")` and `Number("   ")` are both 0.
    if trimmed.isEmpty { return 0 }

    // JS accepts only this exact spelling; "inf" and "nan" are NaN, unlike Swift's `Double`.
    if trimmed == "Infinity" || trimmed == "+Infinity" { return .infinity }
    if trimmed == "-Infinity" { return -.infinity }

    // Radix prefixes, which `Double(_:)` does not accept for binary or octal.
    let lowered = trimmed.lowercased()
    for (prefix, radix) in [("0b", 2), ("0o", 8), ("0x", 16)] where lowered.hasPrefix(prefix) {
      guard let parsed = UInt64(lowered.dropFirst(2), radix: radix) else { return nil }
      return Double(parsed)
    }

    // `Double(_:)` accepts "inf"/"nan" and hex floats; the guards above have already taken
    // the spellings where that differs from JS.
    guard !lowered.contains("inf"), !lowered.contains("nan") else { return nil }
    return Double(trimmed)
  }

  /// `parseFloat` — a prefix parse that stops at the first character it cannot use.
  private static func jsParseFloat(_ raw: String) -> Double? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var end = trimmed.endIndex
    while end > trimmed.startIndex {
      if let parsed = Double(trimmed[trimmed.startIndex..<end]), !parsed.isNaN {
        return parsed
      }
      end = trimmed.index(before: end)
    }
    return nil
  }
}
