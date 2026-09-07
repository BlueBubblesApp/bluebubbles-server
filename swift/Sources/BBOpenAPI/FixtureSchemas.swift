//  FixtureSchemas
//  The payload schemas, as a committed artifact rather than a build-time inference.
//
//  WHY THIS IS A RESOURCE AND NOT A READ OF `Fixtures/http/`: the same document is generated
//  by the `bb-openapi` CLI, where the repository is present, and by `APIDocsView` inside the
//  shipped app, where it is not. A generator that reads the corpus at runtime works in the
//  first case and silently produces a schema-less document in the second — which is the case
//  a user actually sees.
//
//  So inference runs ONCE, deliberately, via `bb-openapi infer-schemas`, and its output is
//  committed here. That also makes the unsoundness manageable: the file is reviewable, and a
//  wrong guess is corrected by editing it rather than by arguing with a heuristic.
//
//  Regenerating OVERWRITES hand corrections. If you fix something here, either re-apply it
//  after the next inference run or teach the inference to get it right — the second is
//  better, and `--check` in CI will tell you when the two have diverged.

import BBSerialization
import Foundation

public enum FixtureSchemas {

  /// Schemas for one operation. Either half may be absent — a GET has no request body, and a
  /// route whose every recording returned no `data` has no response schema.
  public struct Entry: Sendable {
    public let request: OrderedJSON?
    public let response: OrderedJSON?
  }

  /// Keyed by `operationId`, which is what the emitted document references.
  public static let table: [String: Entry] = load()

  /// The file the generator writes and this loads. Relative to the package resources.
  public static let resourceName = "schemas"

  private static func load() -> [String: Entry] {
    guard
      let url = Bundle.module.url(forResource: resourceName, withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let parsed = try? JSONValue.parse(data),
      case .object(let root) = parsed,
      case .object(let operations)? = root["operations"]
    else {
      // Degrades to a schema-less document rather than failing to render one. A missing
      // resource is a packaging mistake, and a viewer that shows the route surface is far
      // more useful than a viewer that shows an error.
      return [:]
    }

    var table: [String: Entry] = [:]
    for (operationID, value) in operations {
      guard case .object(let halves) = value else { continue }
      table[operationID] = Entry(
        request: halves["request"].map(OrderedJSON.init(jsonValue:)),
        response: halves["response"].map(OrderedJSON.init(jsonValue:))
      )
    }
    return table
  }
}

extension OrderedJSON {

  /// Rebuilds an ordered value from a parsed one.
  ///
  /// Object key order is LOST on the way through `JSONValue` — its object case is a
  /// Dictionary — so it is restored by sorting. That is not the same order the generator
  /// wrote, and it does not need to be: what matters is that it is deterministic, so the
  /// emitted document is byte-stable across runs.
  init(jsonValue: JSONValue) {
    switch jsonValue {
    case .null: self = .null
    case .bool(let value): self = .bool(value)
    case .int(let value): self = .int(value)
    case .int64(let value): self = .int(Int(value))
    case .double(let value): self = .double(value)
    case .string(let value): self = .string(value)
    case .array(let values): self = .array(values.map { OrderedJSON(jsonValue: $0) })
    case .object(let fields):
      self = .object(
        fields.keys.sorted().map { key in
          (key: key, value: OrderedJSON(jsonValue: fields[key]!))
        })
    }
  }
}
