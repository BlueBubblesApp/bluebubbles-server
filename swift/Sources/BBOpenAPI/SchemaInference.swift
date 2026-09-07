//  SchemaInference
//  Deriving a JSON Schema from recorded responses.
//
//  The route table knows every path, method, scope and timeout, and NOTHING about payloads —
//  handlers exchange untyped `JSONValue`, so there is no type to reflect on. The recorded
//  corpus is the only description of a payload this project has, so schemas come from there.
//
//  INFERENCE FROM SAMPLES IS UNSOUND, and the whole design here is about being honest about
//  that rather than hiding it:
//
//    - A field that happened to be null in every recording looks like it is always null.
//    - An empty array says nothing about what its elements are.
//    - A field absent from one sample looks optional when it may simply not have applied.
//    - Two recordings of the same route can disagree, and the merge has to widen rather than
//      pick a winner.
//
//  So: every sample for a route is merged rather than the first one winning, `required` means
//  "present in EVERY sample" rather than "present in one", and the output is a DRAFT that is
//  committed and hand-corrected. It is not regenerated on every build — see
//  `bb-openapi infer-schemas`.
//
//  See docs/api/README.md § Schemas.

import BBSerialization
import Foundation

public enum SchemaInference {

  /// A schema inferred from one or more samples of the same value.
  ///
  /// Returns nil for no samples at all, which is different from an empty schema: "we have
  /// never seen this" and "this can be anything" are different claims and a reader deserves
  /// to be able to tell them apart.
  public static func infer(from samples: [JSONValue]) -> OrderedJSON? {
    guard !samples.isEmpty else { return nil }
    guard var merged = samples.first.map(shape(of:)) else { return nil }
    for sample in samples.dropFirst() {
      merged = merge(merged, shape(of: sample))
    }
    return render(merged)
  }

  // MARK: - The intermediate shape

  /// What inference accumulates before it becomes a schema.
  ///
  /// A separate type from `OrderedJSON` because merging two schemas means merging their
  /// property sets and their required sets, and doing that by rewriting emitted JSON would be
  /// parsing back what we just wrote.
  indirect enum Shape {
    case unknown
    case scalar(Set<String>)
    case array(Shape)
    case object(properties: [String: Shape], required: Set<String>, order: [String])

    var isNullOnly: Bool {
      if case .scalar(let types) = self { return types == ["null"] }
      return false
    }
  }

  static func shape(of value: JSONValue) -> Shape {
    switch value {
    case .null: return .scalar(["null"])
    case .bool: return .scalar(["boolean"])
    case .int, .int64: return .scalar(["integer"])
    case .double: return .scalar(["number"])
    case .string: return .scalar(["string"])

    case .array(let elements):
      // An EMPTY array yields `.unknown` items rather than a guess. Emitting `items: {}` is
      // the honest reading: the recording proves the field is a list and proves nothing at
      // all about what goes in it.
      guard !elements.isEmpty else { return .array(.unknown) }
      var element = shape(of: elements[0])
      for other in elements.dropFirst() { element = merge(element, shape(of: other)) }
      return .array(element)

    case .object(let fields):
      var properties: [String: Shape] = [:]
      for (key, child) in fields { properties[key] = shape(of: child) }
      // Sorted so the emitted document is stable; a Dictionary's order is not.
      let order = fields.keys.sorted()
      return .object(properties: properties, required: Set(fields.keys), order: order)
    }
  }

  /// Widens two shapes into one that accepts both.
  ///
  /// Widening, never choosing. If one recording has a string where another has null, the
  /// answer is "string or null" — picking either would produce a schema that rejects a
  /// response this server demonstrably sends.
  static func merge(_ lhs: Shape, _ rhs: Shape) -> Shape {
    switch (lhs, rhs) {
    case (.unknown, let other), (let other, .unknown):
      return other

    case (.scalar(let a), .scalar(let b)):
      return .scalar(a.union(b))

    case (.array(let a), .array(let b)):
      return .array(merge(a, b))

    case (
      .object(let aProps, let aReq, let aOrder),
      .object(let bProps, let bReq, let bOrder)
    ):
      var properties = aProps
      for (key, shape) in bProps {
        properties[key] = properties[key].map { merge($0, shape) } ?? shape
      }
      // REQUIRED IS AN INTERSECTION. A key missing from any one recording is not required,
      // and treating it as required because most samples had it is how a generated client
      // ends up rejecting a legitimate response.
      var order = aOrder
      for key in bOrder where !order.contains(key) { order.append(key) }
      return .object(
        properties: properties, required: aReq.intersection(bReq), order: order.sorted())

    default:
      // A scalar in one recording and an object in another. Rare and real — `data` is a
      // string for `ping` and an object elsewhere. Nothing useful can be said, and saying
      // something anyway would be worse than the empty schema.
      return .unknown
    }
  }

  // MARK: - Rendering

  static func render(_ shape: Shape) -> OrderedJSON {
    switch shape {
    case .unknown:
      return .object([])

    case .scalar(let types):
      let ordered = types.sorted()
      // OpenAPI 3.1 IS JSON Schema, so nullability is a type union rather than 3.0's
      // `nullable: true`. A field seen only as null stays `"null"` — it is what was
      // recorded, and inventing a type for it would be inventing the contract.
      return .obj([
        ("type", ordered.count == 1 ? .string(ordered[0]) : .array(ordered.map { .string($0) }))
      ])

    case .array(let element):
      return .obj([
        ("type", .string("array")),
        ("items", render(element)),
      ])

    case .object(let properties, let required, let order):
      let props = OrderedJSON.object(
        order.compactMap { key in
          properties[key].map { (key: key, value: render($0)) }
        })
      return .obj([
        ("type", .string("object")),
        ("properties", props),
        ("required", required.isEmpty ? nil : .array(required.sorted().map { .string($0) })),
      ])
    }
  }
}
