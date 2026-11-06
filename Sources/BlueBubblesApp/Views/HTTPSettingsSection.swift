//  HTTPSettingsSection
//  The HTTP listener on the Connection page, and the panel behind it.
//
//  Modelled on `ConnectionMethodRow`, deliberately. That row states which method is chosen,
//  says what it is doing, and puts its configuration one button away rather than on a page
//  somebody has to find; the listener deserves exactly the same treatment, and got none:
//  its two settings were loose rows in the Connection form and there was nothing on the page
//  saying the listener existed at all.
//
//  What the panel holds is decided by `HTTPSettingsPanel`, off the view so it can be tested.
//  The rows themselves are `SettingRow`, the SAME view the generated page uses, so the label,
//  the help and the bespoke address picker are the ones the registry declares. A second copy
//  of those fields would drift, and the copy nobody looks at is the one that would be wrong.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import BBBuiltIns
import BBCore
import BBServiceKit
import BBSettings
import SwiftUI

struct HTTPSettingsSection: View {

  let model: AppModel

  @State private var isConfiguring = false

  private var manifest: ServiceManifest { BuiltInManifests.http }

  var body: some View {
    SettingsSection(manifest.name, subtitle: manifest.summary) {
      VStack(alignment: .leading, spacing: 10) {
        // What the listener is doing, in the registry's words. `nil` while it is simply
        // running: a line that says "Running" on a page where everything usually is
        // becomes a line nobody reads, and then the one that says something else is
        // missed with it.
        if let state = stateLine {
          ServiceStatusLine(state)
        }

        // The current answers, so the button is not the only way to find out what the
        // listener is set to. Someone opening the Connection page to check whether they
        // are serving HTTPS should not have to open a sheet to see it.
        Text(summaryProblem ?? summary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Button("Configure HTTP Settings") { isConfiguring = true }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, SettingsMetrics.rowSpacing / 2)
    }
    .task(id: model.phase.isRunning) { await readSummary() }
    .sheet(isPresented: $isConfiguring) {
      HTTPSettingsSheet(
        manifest: manifest, model: model,
        onDone: {
          isConfiguring = false
          Task { await readSummary() }
        })
    }
  }

  // MARK: - The one-line summary

  @State private var bindAddress = ""
  @State private var servesHTTPS = false
  /// Why the summary could not be read, in place of the summary.
  @State private var summaryProblem: String?

  private var summary: String {
    HTTPListenerSummary.summary(bindAddress: bindAddress, servesHTTPS: servesHTTPS)
  }

  private var stateLine: ServiceStatusSummary.Line? {
    ServiceStatusSummary.line(for: model.serviceHealth(manifest.id))
  }

  /// Read directly rather than followed, because neither value changes without this app
  /// writing it: both are edited in the sheet this section opens, and the sheet's Done
  /// re-reads. A follower for two fields nobody else touches would be a stream to maintain
  /// for no change it could ever carry.
  private func readSummary() async {
    do {
      bindAddress = try await model.settings.get(Settings.bindAddress)
      servesHTTPS = try await model.settings.get(Settings.useCustomCertificate)
      summaryProblem = nil
    } catch {
      summaryProblem = DiagnosticText.sentence(for: error)
    }
  }
}

/// The listener's settings, in a sheet.
///
/// `SheetScaffold` with Done and no Cancel, the same chrome as the connection method's
/// Configure sheet and for the same reason: every row here writes as it is changed, so there
/// is nothing held back for a Save button to commit and nothing for a Cancel to undo.
private struct HTTPSettingsSheet: View {

  let manifest: ServiceManifest
  let model: AppModel
  let onDone: () -> Void

  var body: some View {
    SheetScaffold(
      title: manifest.name,
      subtitle: manifest.summary,
      confirmTitle: "Done",
      cancel: .none,
      size: .short,
      confirm: onDone
    ) {
      if model.settings.isAvailable {
        SettingsSection(
          "Listener",
          subtitle: "Where this server accepts connections, and how it answers them."
        ) {
          DividedForEach(HTTPSettingsPanel.settings) { setting in
            SettingRow(setting: setting, model: model)
          }
        }
      } else {
        // The server stopped while the sheet was open; rows over no settings would each
        // report the same failure.
        ServerStoppedNotice(
          model: model, placement: .section(title: "Listener"),
          purpose: "change the listener's settings")
      }
    }
  }
}
