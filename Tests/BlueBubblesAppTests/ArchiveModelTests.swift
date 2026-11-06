//  ArchiveModelTests
//  Export and import keep their own ticks.
//
//  They shared one set, so opening a backup ticked every section it held on the Export side
//  too, and unticking a section to keep it out of an import unticked it from the next export.
//  These drive the model over real storage (an in-memory `app.db`, and a real archive written
//  by the export half) because the shared set only showed once an archive had been opened.

import BBDiagnostics
import BBExport
import BBPersistence
import BBSettings
import BBTestSupport
import Foundation
import Logging
import Testing

@testable import BlueBubblesApp
@testable import BlueBubblesServerCore

@Suite("Archive model", .serialized)
@MainActor
struct ArchiveModelTests {

  /// Storage over an in-memory database, and a directory for the archive and the log.
  private static func storage() async throws -> (ServerComposition.Storage, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-archive-model-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let secrets = InMemorySecretStore()
    let settings = try await TestSettings.store(database: database, secrets: secrets)
    let storage = ServerComposition.Storage(
      logSink: FileSink(url: root.appendingPathComponent("test.log")),
      logger: Logger(label: "bluebubbles.test.archive"),
      appDatabase: database, secrets: secrets, settings: settings)
    return (storage, root)
  }

  @Test("Opening an archive ticks its sections for import and leaves the export ticks alone")
  func openingAnArchiveLeavesExportAlone() async throws {
    let (storage, root) = try await Self.storage()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = ArchiveModel()
    archive.attach(storage: storage)
    defer { archive.detach() }

    archive.exportSelection = [.settings, .webhooks]
    await archive.export(to: root, serverPassword: "")
    let written = try #require(archive.lastExport, "the export failed: \(archive.problem ?? "")")

    // What the person wants next time is narrower than what this archive holds.
    archive.exportSelection = [.settings]
    await archive.inspect(written.url)
    let opened = try #require(archive.pending, "the inspect failed: \(archive.problem ?? "")")

    #expect(archive.importSelection == Set(opened.sections))
    #expect(archive.importSelection == [.settings, .webhooks])
    #expect(archive.exportSelection == [.settings])

    // Keeping a section out of the import keeps it out of the import only.
    archive.exportSelection = [.settings, .webhooks]
    archive.importSelection.remove(.webhooks)
    #expect(archive.exportSelection == [.settings, .webhooks])

    // And cancelling the import forgets its ticks, not the export's.
    archive.discardPending()
    #expect(archive.importSelection.isEmpty)
    #expect(archive.exportSelection == [.settings, .webhooks])
  }
}
