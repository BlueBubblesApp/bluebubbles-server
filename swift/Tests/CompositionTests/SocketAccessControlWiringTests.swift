//  SocketAccessControlWiringTests
//  The composition root hands the socket engine the SAME access controller the HTTP
//  middleware uses.
//
//  Asserted because its absence is silent. `EngineIOServer` takes the controller as an
//  optional, since the protocol tests construct an engine with no server around it, and a
//  nil one means no counting and no blocking. Handshakes keep working either way, so
//  dropping the argument in a refactor would restore the original defect (a socket that
//  authenticates without ever consulting the block list) and break no test that exists.
//
//  Scanned rather than executed: building a real composition needs a database, a keychain
//  and a port. The check is that the argument is present at the one call site, which is
//  exactly the thing that would go missing.

import Foundation
import Testing

@Suite("Socket access control wiring")
struct SocketAccessControlWiringTests {

  private static func compositionSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let path = root.appending(
      path: "Sources/BlueBubblesServerCore/Composition/ServerComposition.swift"
    )
    return try String(contentsOf: path, encoding: .utf8)
  }

  @Test("The engine is constructed with an access controller")
  func engineTakesAccessControl() throws {
    let source = try Self.compositionSource()

    guard let start = source.range(of: "let engineIO = EngineIOServer(") else {
      Issue.record("the composition root no longer constructs an EngineIOServer by that name")
      return
    }
    // The argument list, to its closing paren at the same indentation. Bounded so a later
    // unrelated `accessControl:` elsewhere in the file cannot satisfy this.
    guard let end = source.range(of: "\n    )", range: start.upperBound..<source.endIndex) else {
      Issue.record("could not find the end of the EngineIOServer argument list")
      return
    }
    let arguments = String(source[start.upperBound..<end.lowerBound])

    #expect(
      arguments.contains("accessControl:"),
      """
      The socket engine is being built without an access controller. A handshake would \
      then authenticate without consulting the block list, so a wrong password on the \
      socket would be neither counted nor blocked: the defect SocketAccessControlTests \
      covers. Pass the shared `accessControl` here.
      """
    )
  }

  @Test("It is the shared controller, not a second one")
  func controllerIsShared() throws {
    let source = try Self.compositionSource()

    // One instance across both transports is the property that matters: two would mean two
    // counters, so a client would get its full budget of guesses on each.
    #expect(
      source.contains("accessControl: accessControl"),
      "the engine should receive the controller `makeTransport` was given, not a new one"
    )
    #expect(
      source.contains("makeTransport(storage: storage, accessControl: shared.accessControl)"),
      "the transport should be built with the shared services' controller"
    )
    // And exactly one is ever constructed.
    let constructions = source.components(separatedBy: "AccessControlService(").count - 1
    #expect(
      constructions == 1,
      "expected one AccessControlService in the composition root, found \(constructions)"
    )
  }
}
