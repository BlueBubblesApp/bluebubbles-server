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
          Label(state.text, systemImage: state.symbol)
            .font(.callout)
            .foregroundStyle(state.isProblem ? Color.orange : Color.secondary)
        }

        // The current answers, so the button is not the only way to find out what the
        // listener is set to. Someone opening the Connection page to check whether they
        // are serving HTTPS should not have to open a sheet to see it.
        Text(summary)
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
      if let store = model.settingsStore {
        HTTPSettingsSheet(
          manifest: manifest, store: store,
          onDone: {
            isConfiguring = false
            Task { await readSummary() }
          })
      }
    }
  }

  // MARK: - The one-line summary

  @State private var bindAddress = ""
  @State private var servesHTTPS = false

  private var summary: String {
    let listening =
      switch bindAddress {
      case "", "0.0.0.0", "::": "Listening on every network on this Mac"
      case "127.0.0.1", "::1": "Listening on loopback only"
      default: "Listening on \(bindAddress)"
      }
    return listening + ", " + (servesHTTPS ? "over HTTPS." : "over plain HTTP.")
  }

  private var stateLine: ServiceStatusSummary.Line? {
    ServiceStatusSummary.line(for: model.serviceHealth(manifest.id))
  }

  /// Read directly rather than followed, because neither value changes without this app
  /// writing it: both are edited in the sheet this section opens, and the sheet's Done
  /// re-reads. A follower for two fields nobody else touches would be a stream to maintain
  /// for no change it could ever carry.
  private func readSummary() async {
    guard let store = model.settingsStore else { return }
    bindAddress = await store.get(Settings.bindAddress)
    servesHTTPS = await store.get(Settings.useCustomCertificate)
  }
}

/// The listener's settings, in a sheet.
///
/// Done rather than Cancel/Save, matching the connection method's Configure sheet: every row
/// here writes as it is changed, so there is nothing held back for a Save button to commit
/// and nothing for a Cancel to undo.
private struct HTTPSettingsSheet: View {

  let manifest: ServiceManifest
  let store: SettingsStore
  let onDone: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(manifest.name).font(.headline)
          Text(manifest.summary).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done", action: onDone).keyboardShortcut(.defaultAction)
      }
      .padding()

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
          SettingsSection(
            "Listener",
            subtitle: "Where this server accepts connections, and how it answers them."
          ) {
            ForEach(Array(HTTPSettingsPanel.settings.enumerated()), id: \.element.id) {
              index, setting in
              if index > 0 { SettingsDivider() }
              SettingRow(setting: setting, store: store)
            }
          }
        }
        .padding(20)
      }
    }
    .frame(minWidth: 520, idealWidth: 620, minHeight: 380, idealHeight: 460)
  }
}
