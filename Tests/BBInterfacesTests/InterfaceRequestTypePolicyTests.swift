//  InterfaceRequestTypePolicyTests
//  An interface operation takes typed values, never a raw v1 body.
//
//  The app calls this layer in-process. An operation that takes a `JSONValue` body makes the
//  app build v1 JSON to call it, and the app built it wrong: the schedule sheet's body named
//  no `method`, so every save it made was refused. A v1 body becomes typed in the handler,
//  through a static `parse` or an `init(v1:)` on the request type, and the operation takes the
//  type. This scan holds instance methods to that; statics and initialisers are where the v1
//  reading lives and are not scanned.

import BBTestSupport
import Testing

@Suite("Interfaces take typed requests")
struct InterfaceRequestTypePolicyTests {

  /// A JSON document IS the value here: a backup is a client's own document, stored and
  /// handed back whole, and nothing on this server reads inside it.
  private static let allowed: Set<String> = ["saveBackup"]

  @Test("No interface operation takes a JSONValue parameter")
  func noRawBodies() throws {
    // `public func name(` then the parameter list, across lines, up to a parameter typed
    // `JSONValue` (optional or not). `[^)]` crosses newlines, so a wrapped signature is seen.
    let pattern = try Regex(#"public func (\w+)\([^)]*?:\s*JSONValue\??\s*[,)=]"#)

    var offenders: [String] = []
    for file in try SourceScanner.swiftFiles(under: "Sources/BBInterfaces", minimum: 11) {
      for match in file.code.matches(of: pattern) {
        guard let name = match.output[1].substring.map(String.init) else { continue }
        if Self.allowed.contains(name) { continue }
        offenders.append("\(file.path): \(name)")
      }
    }
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue:
          "an interface operation takes a raw JSON body; give it a request type with an "
          + "init(v1:) the handler calls:\n" + offenders.joined(separator: "\n"))
    )
  }
}
