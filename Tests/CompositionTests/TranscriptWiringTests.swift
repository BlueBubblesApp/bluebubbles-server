//  TranscriptWiringTests
//  The transcript routes reach their handlers, and the handlers need only what they say.
//
//  A module is not done until the composition root calls it and a test asserts that call
//  exists. `RouteRegistrationTests` holds the group in the always-mounted set; this holds
//  the other half: that registering `TranscriptHandlers` against a host offering exactly
//  the two capabilities it declares leaves no route in the group without a controller.

import BBHTTPAPI
import BBMedia
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Transcript wiring")
struct TranscriptWiringTests {

  private struct Host: InterfaceProviding, TranscriptExportStoring {
    let transcriptExports = TranscriptExportStore(
      directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("bb-exports-test-\(UUID().uuidString)"))
    func interfaces() async -> ServerInterfaces? { nil }
    func requireInterfaces() async throws -> ServerInterfaces {
      throw InterfaceError.unavailable("the iMessage database is not readable")
    }
  }

  @Test("Every transcript route has a handler behind it")
  func routesAreCovered() {
    var registry = HandlerRegistry()
    TranscriptHandlers.register(into: &registry, context: Host())
    #expect(registry.missing(for: [AdditiveRoutes.transcripts]).isEmpty)
  }

  @Test("The export route is in the catalogue and the always-mounted set")
  func routeIsMounted() async {
    let groups = await ServerComposition.routeGroups(authMode: .password, codecs: .legacyOnly())
    #expect(groups.contains { $0.name == AdditiveRoutes.transcripts.name })
    let export = AdditiveRoutes.transcripts.routes.first { $0.handlerID == .transcriptExport }
    #expect(export?.responseTimeout == .seconds(3600))
  }

  @Test("The export store reserves a private folder and sweeps stale ones")
  func exportStore() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-exports-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TranscriptExportStore(directory: root, maximumAge: 0)
    let first = try store.reserve()
    #expect(FileManager.default.fileExists(atPath: first.path))
    // Zero age: the next reservation removes the last one.
    let second = try store.reserve()
    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
  }
}
