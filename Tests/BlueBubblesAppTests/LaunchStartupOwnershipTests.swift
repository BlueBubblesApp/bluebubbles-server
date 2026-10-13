//  LaunchStartupOwnershipTests
//  The server is started from the application delegate, never from a view.
//
//  REGRESSION TEST. Startup lived in the main window's `.task`, which assumes a window opens.
//  One does not always open: AppKit pairs `-key value` arguments into `NSArgumentDomain` and
//  reads anything left over as a file to open, and a launch that asks it to open a file opens
//  no window of its own. `--headless --set k=v` leaves one over every time, because
//  `--headless` takes no value, so AppKit pairs it with `--set` and `k=v` is the leftover.
//
//  Measured on a live build: `--headless` alone started normally; `--headless --set
//  socket_port=15879` never ran the window's `.task` at all; so did a bare `BlueBubbles hello`.
//  The server never came up and said nothing about it, because `AppModel.start`'s only report
//  of a failure is `phase`, and headless has no window to show a phase in: a process that
//  looked alive, served nothing, and logged not one line.
//
//  A scan rather than a behavioural test: the defect is WHERE startup is called from, and the
//  call itself opens two databases and binds a port, which a unit test must not do.

import BBTestSupport
import Foundation
import Testing

@Suite("Launch startup ownership")
struct LaunchStartupOwnershipTests {

  private static func entryPointFile() throws -> SourceFile {
    try SourceScanner.file("Sources/BlueBubblesApp/BlueBubblesApp.swift")
  }

  /// The entry point's code, comments removed: the anchors below are declarations and calls.
  private static func entryPoint() throws -> String { try entryPointFile().code }

  /// A FLOOR on what was scanned. A scan whose anchors have been renamed finds no offender
  /// and passes, and the rule then stops being enforced while looking exactly like
  /// compliance.
  @Test("The entry point still has the shape this suite reasons about")
  func anchorsExist() throws {
    let source = try Self.entryPoint()
    #expect(source.contains("var body: some Scene"))
    #expect(source.contains("final class AppDelegate"))
    #expect(
      source.contains("func applicationDidFinishLaunching"),
      "startup has to hang off a message that arrives whether or not a window opens")
  }

  /// The scene may close a window. It may not start the server.
  @Test("No scene starts the server")
  func sceneDoesNotStart() throws {
    let file = try Self.entryPointFile()
    let lines = file.lines
    let delegate = try #require(lines.firstIndex { $0.code.contains("final class AppDelegate") })
    let scene = lines[..<delegate]

    let offences = scene.filter { line in
      line.code.contains("beginStart(") || line.code.contains("model.start(")
    }.map { Offence(file, $0) }
    #expect(
      offences.isEmpty,
      """
      The server is started from a scene, which only runs if a window opens: \
      \(offences.report)
      """)
  }

  /// And the delegate must actually do it, or the app starts nothing at all.
  @Test("The delegate starts the server when the app finishes launching")
  func delegateStarts() throws {
    let source = try Self.entryPoint()
    let delegate = try #require(source.range(of: "final class AppDelegate"))
    let body = source[delegate.lowerBound...]
    #expect(body.contains("beginStart("))
    #expect(
      source.components(separatedBy: "beginStart(").count - 1 == 1,
      "one caller, so there is one answer to when the server starts")
  }
}
