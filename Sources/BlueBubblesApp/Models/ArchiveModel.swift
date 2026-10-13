//  ArchiveModel
//  Exporting this server to a ZIP, and reading one back.
//
//  A child model rather than a facade, for the reason `MigrationModel` is one: this owns
//  work with its own lifetime. An export walks every table and shells out to `ditto`, an
//  import unpacks into a temporary directory that must be cleaned up whether or not the
//  person goes through with it, and both have a result worth keeping on screen afterwards.
//  None of that belongs in a view, and a view cannot own the cleanup.
//
//  **The two halves are asymmetric on purpose.** An export is one action: tick, press, done.
//  An import is inspect-then-apply, so what is about to be overwritten can be read before
//  anything is. `ServerImporter` splits those into two calls precisely so a UI can put a
//  decision between them.
//
//  The password is held in `@State` on the view and passed in, never stored here. It is the
//  server's own password; keeping a copy on a model that outlives the sheet would be a
//  credential sitting in memory for the life of the app for no reason.

import BBCore
import BBExport
import BlueBubblesServerCore
import Foundation
import Observation

@Observable
@MainActor
final class ArchiveModel {

  /// What the person has ticked. Configuration only until they say otherwise; see
  /// `ExportSection.defaultSelection`.
  var selection: Set<ExportSection> = ExportSection.defaultSelection

  /// An export or import is running. Every button disables on it, so a second press cannot
  /// start a second walk over the same tables.
  private(set) var isWorking = false

  /// The last export, kept so the section can offer to reveal it in the Finder.
  private(set) var lastExport: ServerExporter.Report?

  /// An archive that has been opened and not yet applied or dismissed.
  private(set) var pending: ServerImporter.Inspection?
  /// What the last import changed.
  private(set) var lastImport: ServerImporter.Report?

  /// The sentence to show when something failed. Through `DiagnosticText`, never a raw
  /// enum; see the app's `CLAUDE.md`.
  private(set) var problem: String?

  private var storage: ServerComposition.Storage?

  var isAttached: Bool { storage != nil }

  func attach(storage: ServerComposition.Storage) {
    self.storage = storage
  }

  func detach() {
    storage = nil
    discardPending()
    lastExport = nil
    lastImport = nil
    problem = nil
  }

  // MARK: - Export

  /// Writes the ticked sections into `directory`.
  ///
  /// - Parameter serverPassword: only read when `.secrets` is ticked. `ServerExporter`
  ///   checks it against this server's own password and refuses anything else, which is
  ///   what stops an export granting an ability the person did not already have.
  func export(to directory: URL, serverPassword: String) async {
    guard !isWorking else { return }
    guard let storage else {
      problem = ServerNotRunning().body
      return
    }
    isWorking = true
    problem = nil
    defer { isWorking = false }

    do {
      lastExport = try await storage.exporter().export(
        sections: selection, to: directory, serverPassword: serverPassword)
    } catch {
      lastExport = nil
      problem = DiagnosticText.sentence(for: error)
    }
  }

  // MARK: - Import

  /// Opens an archive and reports what is in it. Writes nothing.
  func inspect(_ archive: URL) async {
    guard !isWorking else { return }
    guard let storage else {
      problem = ServerNotRunning().body
      return
    }
    isWorking = true
    problem = nil
    defer { isWorking = false }

    // A previous inspection's directory goes first: two open at once would leak the older
    // one, and it holds somebody's settings in the clear.
    discardPending()
    lastImport = nil

    do {
      let inspection = try await storage.importer().inspect(archive)
      pending = inspection
      // Everything the archive offers, pre-ticked. This is a restore: somebody who opened
      // a backup means to put it back, and the ticks are there to take things OUT.
      selection = Set(inspection.sections)
    } catch {
      problem = DiagnosticText.sentence(for: error)
    }
  }

  /// Applies the sections still ticked on the pending inspection.
  func applyPending(serverPassword: String) async {
    guard !isWorking, let inspection = pending else { return }
    guard let storage else {
      problem = ServerNotRunning().body
      return
    }
    isWorking = true
    problem = nil
    defer { isWorking = false }

    let importer = storage.importer()
    do {
      let sections = selection
      lastImport = try await asOperator {
        try await importer.apply(inspection, sections: sections, serverPassword: serverPassword)
      }
      discardPending()
    } catch {
      // The inspection is KEPT on a failure. A wrong password is the likely reason, and
      // making somebody choose the file again to retype it would be the wrong lesson to
      // draw from a typo.
      problem = DiagnosticText.sentence(for: error)
    }
  }

  /// Forgets an opened archive and removes what it was unpacked into.
  ///
  /// Called on cancel, on a new inspection, on a successful apply and on detach. The
  /// directory holds the archive's contents in the clear — the same material the export
  /// went to trouble over — so every path out of here removes it.
  func discardPending() {
    guard let inspection = pending else { return }
    try? FileManager.default.removeItem(at: inspection.directory)
    pending = nil
  }
}
