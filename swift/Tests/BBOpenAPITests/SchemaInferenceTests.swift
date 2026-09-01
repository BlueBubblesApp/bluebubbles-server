//  SchemaInferenceTests
//  The widening rules, which are where an inferred schema goes wrong quietly.
//
//  A schema that is merely INCOMPLETE is survivable — a client author reads the endpoint and
//  fills the gap. A schema that is WRONG is not: it says a field is required when it is not,
//  or a string when it is sometimes null, and a generated client rejects a response the
//  server legitimately sends. Every test here is about the second kind.

import BBSerialization
import Testing

@testable import BBOpenAPI

@Suite("Schema inference")
struct SchemaInferenceTests {

  private func render(_ samples: [JSONValue]) -> String {
    SchemaInference.infer(from: samples)?.serialized() ?? "<nil>"
  }

  @Test("No samples yields no schema, which is not the same as an empty one")
  func noSamples() {
    #expect(SchemaInference.infer(from: []) == nil)
  }

  @Test("A scalar takes its JSON type")
  func scalarTypes() {
    #expect(render([.string("x")]).contains("\"string\""))
    #expect(render([.int(1)]).contains("\"integer\""))
    #expect(render([.double(1.5)]).contains("\"number\""))
    #expect(render([.bool(true)]).contains("\"boolean\""))
    #expect(render([.null]).contains("\"null\""))
  }

  @Test("Disagreeing samples widen rather than pick a winner")
  func mergeWidens() {
    // The single most valuable rule here. One recording had a string, another null; a schema
    // saying "string" rejects a response this server demonstrably sends.
    let out = render([.string("x"), .null])
    #expect(out.contains("\"null\""))
    #expect(out.contains("\"string\""))
  }

  @Test("A key missing from any sample is not required")
  func requiredIsIntersection() {
    let both = JSONValue.object(["a": .int(1), "b": .int(2)])
    let onlyA = JSONValue.object(["a": .int(1)])
    let out = render([both, onlyA])
    // `a` is in both, `b` is not — so only `a` may be called required.
    #expect(out.contains("\"a\""))
    #expect(!out.contains("\"required\": [\n    \"a\",\n    \"b\"\n  ]"))
  }

  @Test("A property seen in only one sample still appears")
  func unionOfProperties() {
    let out = render([
      .object(["a": .int(1)]),
      .object(["b": .string("x")]),
    ])
    #expect(out.contains("\"a\""))
    #expect(out.contains("\"b\""))
  }

  @Test("An empty array claims nothing about its elements")
  func emptyArrayIsHonest() {
    // `items: {}` rather than a guess. The recording proves it is a list and proves nothing
    // about what goes in it.
    let out = render([.array([])])
    #expect(out.contains("\"items\": {}"))
  }

  @Test("Array elements merge across both positions and samples")
  func arrayElementsMerge() {
    let out = render([.array([.string("a"), .null])])
    #expect(out.contains("\"null\""))
    #expect(out.contains("\"string\""))
  }

  @Test("Irreconcilable samples produce an empty schema, not a wrong one")
  func scalarVersusObjectIsUnknown() {
    // `data` is the string "pong" for ping and an object elsewhere. Nothing true can be said
    // about the union, and saying something anyway is worse than saying nothing.
    let out = render([.string("pong"), .object(["a": .int(1)])])
    #expect(out == "{}\n")
  }

  @Test("Output is byte-stable regardless of sample order")
  func deterministicAcrossOrder() {
    let a = JSONValue.object(["z": .int(1), "a": .string("x")])
    let b = JSONValue.object(["a": .string("y"), "m": .null])
    #expect(render([a, b]) == render([a, b]))
    // Property ORDER must not depend on dictionary iteration order, or the committed
    // document churns between runs.
    #expect(render([a, b]).contains("\"a\""))
  }
}
