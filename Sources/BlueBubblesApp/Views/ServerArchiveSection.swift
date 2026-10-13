//  ServerArchiveSection
//  Export and import, on the Advanced settings tab.
//
//  **The checkbox list is the feature, not the ZIP.** What leaves this Mac is the decision
//  being made, so each row carries what it actually holds — "Messages waiting to be sent,
//  and the record of ones already sent — including their text" rather than "Scheduled
//  messages" — and the ones holding somebody's data or credentials are marked. A list of
//  bare nouns invites ticking everything and emailing the result.
//
//  `ExportSection` owns that copy so this view and the `--sections` flag cannot describe the
//  same thing two ways.
//
//  **Import is two steps with a decision between them.** Choosing a file opens it and
//  reports what is inside; nothing is written until Import is pressed against that summary.
//  `ServerImporter` splits `inspect` from `apply` for exactly this.
//
//  Emits sections, not a page: the host scrolls.

import AppKit
import BBExport
import SwiftUI

struct ServerArchiveSection: View {

  @Bindable var model: AppModel

  /// The server password, for the one section that needs it. Held here and not on
  /// `ArchiveModel`: it lives as long as this view does, which is as long as it is needed.
  @State private var password = ""
  @State private var confirmingImport = false

  private var archive: ArchiveModel { model.archive }

  var body: some View {
    Group {
      if model.phase.isRunning {
        exportSection
        importSection
      } else {
        ServerStoppedNotice(
          model: model,
          placement: .section(title: "Export & Import"),
          purpose: "export this server's configuration or read one back")
      }
    }
  }

  // MARK: - Export

  private var exportSection: some View {
    SettingsSection("Export", subtitle: Self.exportSubtitle) {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(ExportSection.allCases) { section in
          row(for: section)
        }

        if archive.selection.contains(.secrets) {
          Divider()
          secretsField
        }

        Divider()
        HStack {
          if let report = archive.lastExport {
            // The path is what somebody needs next, so it is selectable rather than
            // described. `CopyableValue` is the one way this app presents one.
            CopyableValue(report.url.path)
          }
          Spacer(minLength: 16)
          if let report = archive.lastExport {
            Button("Show in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([report.url])
            }
          }
          Button("Export…") { Task { await chooseDestination() } }
            .buttonStyle(.borderedProminent)
            .disabled(archive.isWorking || archive.selection.isEmpty)
        }
      }
      .padding(.vertical, 2)
      // Unticking the credentials forgets the password typed for them: it is held only for
      // the one section that needs it, and a password that outlives its reason sits in
      // memory for nothing.
      .onChange(of: archive.selection.contains(.secrets)) { _, includesSecrets in
        if !includesSecrets { password = "" }
      }
    } trailing: {
      if archive.isWorking {
        ProgressView().controlSize(.small)
      }
    }
  }

  private static let exportSubtitle =
    "Write the parts you choose to a ZIP file. Everything except passwords and keys is "
    + "plain JSON you can open and read."

  private func row(for section: ExportSection) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Toggle(isOn: Binding(contains: section, in: Bindable(archive).selection)) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(section.title).font(.callout)
            if section.isSensitive {
              // Tinted because it is a judgement about the row, not a description of it;
              // see the rule on `Tag` in the app's `CLAUDE.md`.
              Tag(section == .secrets ? "Credentials" : "Personal", tint: StatusTone.attention.tint)
            }
          }
          Text(section.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(.checkbox)
      Spacer(minLength: 0)
    }
    // The title and its explanation are one thing to read, not two stops.
    .accessibilityElement(children: .combine)
  }

  private var secretsField: some View {
    VStack(alignment: .leading, spacing: 6) {
      SecureField("Server password", text: $password)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 320)
      Text(
        "Required, and it must be this server's password. It encrypts the passwords and "
          + "keys inside the file, so importing them later asks for it again. A server "
          + "with no password set cannot export them at all."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: - Import

  private var importSection: some View {
    SettingsSection("Import", subtitle: Self.importSubtitle) {
      VStack(alignment: .leading, spacing: 12) {
        if let problem = archive.problem {
          // `NoticeBody`, not `NoticeCard`: the section is already the card, and glass
          // inside glass samples the glass.
          NoticeBody(
            symbol: "exclamationmark.triangle.fill", title: "That did not work",
            tone: .problem, messages: [problem])
        }

        if let inspection = archive.pending {
          pendingCard(inspection)
        } else if let report = archive.lastImport {
          NoticeBody(
            symbol: "checkmark.circle.fill", title: "Imported",
            tone: .good,
            messages: [
              report.applied.map { "\($0.title): \(report.counts[$0] ?? 0)" }
                .joined(separator: ", "),
              "Restart the server for every change to take effect.",
            ]
              + (report.skippedSettings.isEmpty
                ? []
                : [
                  "Left alone, because they describe a particular server: "
                    + report.skippedSettings.joined(separator: ", ")
                ])
          )
        }

        HStack {
          Spacer(minLength: 0)
          if archive.pending != nil {
            Button("Cancel") { archive.discardPending() }
              .disabled(archive.isWorking)
            Button("Import") { confirmingImport = true }
              .buttonStyle(.borderedProminent)
              .disabled(archive.isWorking || archive.selection.isEmpty)
          } else {
            Button("Choose a File…") { Task { await chooseArchive() } }
              .disabled(archive.isWorking)
          }
        }
      }
      .padding(.vertical, 2)
    }
    // Replacing what is here with somebody else's settings is exactly the shape this app
    // confirms: it destroys something the person made. See the app's `CLAUDE.md`.
    .confirmationDialog(
      "Replace these parts of this server?",
      isPresented: $confirmingImport, titleVisibility: .visible
    ) {
      Button("Replace", role: .destructive) {
        Task {
          await archive.applyPending(serverPassword: password)
          password = ""
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "The sections you have ticked will be replaced by what is in the file. This "
          + "cannot be undone."
      )
    }
  }

  private static let importSubtitle =
    "Read a file written by Export back into this server. Nothing is changed until you "
    + "confirm."

  /// A block inside the Import section rather than a card of its own: the section is the
  /// card.
  private func pendingCard(_ inspection: ServerImporter.Inspection) -> some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.cardStackSpacing) {
      Text("This file contains").font(.headline)
      ForEach(inspection.sections) { section in
        Toggle(isOn: Binding(contains: section, in: Bindable(archive).selection)) {
          HStack(spacing: 6) {
            Text(section.title).font(.callout)
            if section == .secrets {
              Text("encrypted").font(.caption).foregroundStyle(.secondary)
            } else {
              Text("\(inspection.counts[section] ?? 0)")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        .toggleStyle(.checkbox)
        .accessibilityElement(children: .combine)
      }

      if inspection.hasSecrets, archive.selection.contains(.secrets) {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
          SecureField("Password used when this export was made", text: $password)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 380)
          Text(
            "This is the password of the server the file came from, which may not be "
              + "this one's."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  // MARK: - Panels

  /// Where to write. A directory rather than a file, because the NAME carries the
  /// timestamp and is `ExportManifest`'s to decide — letting somebody rename it in a save
  /// panel would produce archives that no longer sort or say when they were made.
  private func chooseDestination() async {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Export"
    panel.message = "Choose where to save the export."
    guard panel.runModal() == .OK, let directory = panel.url else { return }
    await archive.export(to: directory, serverPassword: password)
    password = ""
  }

  private func chooseArchive() async {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.zip]
    panel.message = "Choose a BlueBubbles export."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    await archive.inspect(url)
  }
}
