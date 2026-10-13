//  ServerArchiveCommands
//  `--export` and `--import` on the command line.
//
//  The headless half of the same feature the settings screen offers. A server run without a
//  UI is exactly the one whose configuration is worth being able to carry somewhere, so a
//  checkbox is not a sufficient home for this.
//
//  **The password is read from the terminal, never from a flag.** `ps` shows another user's
//  argv on this platform, and shell history keeps it afterwards. `getpass` is the ordinary
//  way to ask and is what `ssh` and `sudo` use; it also means the value never reaches a
//  process listing even for the instant the command runs.

import ArgumentParser
import BBCore
import BBExport
import BlueBubblesServerCore
import Foundation

extension BlueBubblesServerCommand {

  /// Parses `--sections`, or answers the configuration-only default.
  static func parseSections(_ raw: String?) throws -> Set<ExportSection> {
    guard let raw, !raw.isEmpty else { return ExportSection.defaultSelection }
    var chosen: Set<ExportSection> = []
    for name in raw.split(separator: ",") {
      let trimmed = name.trimmingCharacters(in: .whitespaces)
      guard let section = ExportSection(rawValue: trimmed) else {
        // Named, with the list, rather than "invalid": somebody who typed `webhook` for
        // `webhooks` should not have to go and find the spelling.
        throw ValidationError(
          "There is no section called \"\(trimmed)\". Choose from: "
            + ExportSection.allCases.map(\.rawValue).joined(separator: ", "))
      }
      chosen.insert(section)
    }
    return chosen
  }

  /// What `--import` restores, from `--sections` and what the archive actually holds.
  ///
  /// Refused rather than narrowed, in both directions a person can get it wrong: a name that
  /// is not a section (`webhook` for `webhooks`), and a real section this archive does not
  /// contain. Either way the import would otherwise run and do something other than what was
  /// asked, and an import is not easily undone. `ServerImporter.apply` restores only what the
  /// archive holds, so this is the only place the second mistake can be caught.
  ///
  /// No `--sections` is everything in the archive; an empty one is `--export`'s default.
  static func importSections(
    _ raw: String?, available: [ExportSection]
  ) throws -> Set<ExportSection> {
    let inArchive = Set(available)
    guard let raw else { return inArchive }
    if raw.isEmpty { return ExportSection.defaultSelection.intersection(inArchive) }

    let requested = try parseSections(raw)
    let missing = ExportSection.allCases.filter {
      requested.contains($0) && !inArchive.contains($0)
    }
    guard missing.isEmpty else {
      throw ValidationError(
        "This export does not contain "
          + missing.map(\.rawValue).joined(separator: ", ")
          + ". It holds: " + available.map(\.rawValue).joined(separator: ", "))
    }
    return requested
  }

  /// Asks for a password without echoing it or putting it in argv. See the header.
  static func askForPassword(_ prompt: String) -> String {
    guard let raw = getpass(prompt) else { return "" }
    return String(cString: raw)
  }

  static func exportAndExit(
    storage: ServerComposition.Storage, directory: String, sections: String?
  ) async throws {
    let chosen = try parseSections(sections)
    let destination = URL(fileURLWithPath: directory, isDirectory: true)

    var password = ""
    if chosen.contains(.secrets) {
      password = askForPassword("Server password (required to export secrets): ")
      guard !password.isEmpty else {
        throw ValidationError(SecretsEnvelope.Failure.noServerPassword.body)
      }
    }

    let report = try await storage.exporter().export(
      sections: chosen, to: destination, serverPassword: password)

    print("Wrote \(report.url.path)")
    for section in report.sections {
      print("  \(section.rawValue): \(report.counts[section] ?? 0)")
    }
    if !chosen.contains(.secrets) {
      // Said out loud, because "I exported my server" and "I exported everything needed to
      // run it" are different things and only one of them is true here.
      print("")
      print("Passwords and keys are NOT in this file. Add --sections …,secrets to include")
      print("them; you will be asked for the server password, which encrypts them.")
    }
  }

  static func importAndExit(
    storage: ServerComposition.Storage, archive: String, sections: String?, dryRun: Bool
  ) async throws {
    let importer = storage.importer()
    let inspection = try await importer.inspect(URL(fileURLWithPath: archive))
    // It holds the archive's contents in the clear, which is the material the export was
    // careful about.
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    // Before anything is printed or asked, so a dry run refuses the same request a real
    // import would.
    let chosen = try importSections(sections, available: inspection.sections)

    print("Export from \(inspection.manifest.serverVersion), made \(inspection.manifest.createdAt)")
    for section in inspection.sections where section != .secrets {
      print("  \(section.rawValue): \(inspection.counts[section] ?? 0)")
    }
    if inspection.hasSecrets { print("  secrets: present, encrypted") }

    guard !dryRun else {
      print("")
      print("Nothing was changed. Run again without --dry-run to apply it.")
      return
    }

    var password = ""
    if chosen.contains(.secrets) {
      password = askForPassword("Password used when this export was made: ")
    }

    let report = try await importer.apply(
      inspection, sections: chosen, serverPassword: password)
    print("")
    for section in report.applied {
      print("Imported \(section.rawValue): \(report.counts[section] ?? 0)")
    }
    if !report.skippedSettings.isEmpty {
      // Named individually. These are keys somebody's archive carried and this server
      // declined, and a count alone would leave them guessing which.
      print("")
      print("Left alone, because they describe a particular server:")
      for key in report.skippedSettings { print("  \(key)") }
    }
    print("")
    print("Restart the server for every change to take effect.")
  }
}
