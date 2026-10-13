//  HandlerBoundaryPolicyTests
//  A handler parses, calls one interface, and serializes. It does not reach the helper.
//
//  The architecture's test for where logic belongs is "could the SwiftUI window call this
//  without going through HTTP?" A handler that takes the Private API client itself, or the
//  FaceTime coordinator, or the FindMy runtime, fails that test: the FaceTime dial handler
//  grew a pre-flight, a dial, a link, a ledger write and a hand-off before anything noticed,
//  and the app could reach none of it. `FaceTimeInterface` and `FindMyInterface` hold those
//  now, and this scan keeps them there, in the shape of `SettingKeyLiteralTests`.
//
//  There is no allowlist, and the scan has a second reason to exist: a call made from a
//  handler also skips `throughMessages`, so a Messages refusal reaches the client as a
//  generic `Server Error` rather than the `iMessage Error` it branches on.

import BBTestSupport
import Testing

@Suite("Handlers stay on their side of the interface boundary")
struct HandlerBoundaryPolicyTests {

  @Test("No handler takes the Private API client, the FaceTime coordinator or the FindMy runtime")
  func noDirectHelperReach() throws {
    let pattern = try Regex(
      #"requirePrivateAPI\(|privateAPIClient\(\)|\.faceTime\(\)|\.findMy\.|\.findMy\b(?!Interface)"#
    )
    // The capability protocols themselves are declared beside the handlers.
    let files = try Self.handlers()
      .filter { $0.path != "Sources/BBHandlers/HandlerCapabilities.swift" }
    let offences = SourceScanner.offences(in: files) { _, line in line.code.contains(pattern) }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue:
          "a handler reaches the helper directly; put the operation on an interface and call that:\n"
          + offences.report)
    )
  }

  /// Every handler source, with a floor so an empty directory cannot pass as a clean one.
  private static func handlers() throws -> [SourceFile] {
    try SourceScanner.swiftFiles(under: "Sources/BBHandlers", minimum: 11)
  }

  /// A handler declares no serializer. A projection lives beside the type it projects (a
  /// `static` on the interface, or `json` on the record) so the app and a test reach the shape
  /// the route sends without HTTP. Five handler groups held their own before they moved.
  ///
  /// `errorMetadata` is allowed: it builds the `metadata.errors` of a batch envelope out of
  /// the entries the HANDLER was sent, which is transport, not a projection of a domain type.
  @Test("No handler declares a function that builds a JSON value")
  func noHandlerSerializers() throws {
    let allowed: Set<String> = ["errorMetadata"]
    // A declaration whose return type is `JSONValue` or `[String: JSONValue]`, optional or
    // not, across a wrapped signature. `[JSONValue]` is a request read, not a projection.
    let pattern = try Regex(
      #"func (\w+)(<[^>]*>)?\([^)]*\)\s*(async\s+)?(throws\s+)?->\s*(JSONValue|\[String:\s*JSONValue\])\??\s*\{"#
    )

    var offenders: [String] = []
    for file in try Self.handlers() {
      for match in file.code.matches(of: pattern) {
        guard let name = match.output[1].substring.map(String.init) else { continue }
        if allowed.contains(name) { continue }
        offenders.append("\(file.path): \(name)")
      }
    }
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue:
          "a handler declares a serializer; move it beside the type it projects:\n"
          + offenders.joined(separator: "\n"))
    )
  }

  /// A handler never spawns a task. Work that outlives the request belongs to an owner that
  /// can cancel it when the service behind it stops: `ServerLifecycle.schedule` for a
  /// restart, `ApplicationRestartCoordinator` for an app, `FaceTimeCoordinator` for a
  /// hand-off. The two server restarts were bare `Task { … }`s beside a coordinator that
  /// already did this properly.
  @Test("No handler spawns a task that nothing owns")
  func noUnownedTasks() throws {
    let pattern = try Regex(#"\bTask\s*(\{|\(|\.detached)"#)
    let offences = SourceScanner.offences(in: try Self.handlers()) { _, line in
      line.code.contains(pattern)
    }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue:
          "a handler spawns a task nothing owns; hand the work to an owner that can stop it:\n"
          + offences.report)
    )
  }
}
