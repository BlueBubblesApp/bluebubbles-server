//  ConnectionMethodRow
//  Choosing a connection method, and getting to its configuration.
//
//  The problem this solves is the one that makes "configure it on its own page" annoying: the
//  user picks ngrok here, ngrok needs an auth token, and nothing on this screen says so or
//  offers a way there. They find out when the tunnel fails to start.
//
//  So the row reports what the CHOSEN method still needs, inline, and resolves it here: the
//  sheet edits the same fields the service's own page does, and the download button fetches
//  the binary without leaving.
//
//  There WAS a second button opening the service's page, justified by that page being where
//  the binary and the permissions lived. The binary is now handled in this row, which left
//  two buttons a step apart in specificity — "Configure…" and "Open ngrok" — where the
//  difference between them was not something a reader could infer. One button, named after
//  the thing it configures.
//
//  See `.claude/docs/architecture.md`.

import BBHandlers
import BBInterfaces
import BBServiceKit
import BBSettings
import BBTooling
import BlueBubblesServerCore
import SwiftUI

struct ConnectionMethodRow: View {

  let setting: AnySetting
  let selection: String
  let onChange: (String) -> Void

  @Environment(AppModel.self) private var model
  @State private var isConfiguring = false
  @State private var missing: [FieldDescriptor] = []

  private var manifest: ServiceManifest? {
    BuiltInManifests.all.first { $0.id.rawValue == selection }
  }

  /// The binary this method needs, if it declares one.
  ///
  /// Read from the manifest rather than a list of tunnel names here, so a third-party
  /// connection method that declares a tool gets the same warning and the same button
  /// without this file learning about it.
  private var requiredTool: ManagedToolDescriptor? { manifest?.tools.first }

  private var toolStatus: ToolStatus? {
    requiredTool.flatMap { model.toolStatus($0.id) }
  }

  /// Whether the tool is missing, as the SERVICE would see it.
  ///
  /// `executablePath` is "what a service would actually be handed right now", so it covers
  /// a binary the user pointed at themselves as well as a managed install — which a check
  /// for "is it installed" would report as missing while the tunnel worked fine.
  ///
  /// nil status means the stream has not delivered one yet; assuming missing would flash a
  /// warning on every appearance.
  /// Whether the last install attempt failed, so the summary reads as an error rather than
  /// as progress.
  private var isToolInstallFailed: Bool {
    if case .failed = toolStatus?.activity { return true }
    return false
  }

  private var isToolMissing: Bool {
    guard requiredTool != nil, let toolStatus else { return false }
    return toolStatus.executablePath == nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      SettingsRow(
        title: setting.presentation.label,
        help: setting.presentation.help,
        // The specific thing that is missing, named. "ngrok needs an Auth Token" is
        // actionable; "not configured" sends someone hunting.
        footnotes: [missingNote, toolNote].compactMap { $0 }
      ) {
        Picker(
          "",
          selection: Binding(
            get: { selection },
            set: { onChange($0) }
          )
        ) {
          ForEach(ConnectionMethodChoices.available()) { choice in
            Text(choice.label).tag(choice.value)
          }
        }
        .labelsHidden()
        .controlSize(.large)
        .frame(maxWidth: 280)
      }

      if let manifest, !manifest.settings.isEmpty {
        HStack(spacing: 12) {
          // Offered right here rather than only on the service's own page, because this is
          // the moment the user learns they need it.
          if isToolMissing, let requiredTool, toolStatus?.activity == .idle {
            Button("Download \(requiredTool.displayName)") {
              Task { await model.installTool(requiredTool.id) }
            }
            .buttonStyle(.borderedProminent)
          }
          Button("Configure \(manifest.name)") { isConfiguring = true }
          Spacer()
        }
        // These buttons hang BELOW the `SettingsRow`, which is what carries the row rhythm
        // — so they fell outside it and sat flush against the next divider, reading as
        // though they belonged to the setting underneath. Half the row spacing, matching
        // what `SettingsRow` puts below its own content.
        .padding(.bottom, SettingsMetrics.rowSpacing / 2)
      }
    }
    .task(id: selection) { await refresh() }
    // Followed rather than read once: an install runs for tens of seconds, and a row that
    // sampled the status would show "not downloaded" for all of it.
    .task { model.beginObservingTools() }
    .onDisappear { model.endObservingTools() }
    .sheet(isPresented: $isConfiguring) {
      if let manifest, let store = model.settingsStore {
        ConfigureSheet(
          manifest: manifest, store: store,
          onDone: {
            isConfiguring = false
            Task { await refresh() }
          })
      }
    }
  }

  private var missingNote: SettingsFootnote? {
    guard let manifest, !missing.isEmpty else { return nil }
    return SettingsFootnote(
      text: "\(manifest.name) needs: " + missing.map(\.label).joined(separator: ", "),
      symbol: "exclamationmark.circle",
      tone: .warning
    )
  }

  /// The same treatment a missing token gets, for a missing binary.
  ///
  /// Without it, choosing ngrok looked complete: the picker showed ngrok, no field was
  /// blank, and the tunnel then failed to start with the reason only in the log. A binary
  /// that has not been downloaded is a required thing that is missing, exactly like an
  /// empty auth token, and now reads as one.
  private var toolNote: SettingsFootnote? {
    guard let manifest, let requiredTool else { return nil }
    if let summary = toolStatus?.activitySummary, toolStatus?.activity != .idle {
      // Progress and failure both come from the tool manager's own wording, so this row
      // and the Integrations page never describe the same install differently.
      return SettingsFootnote(
        text: summary, symbol: "arrow.down.circle",
        tone: isToolInstallFailed ? .error : .neutral
      )
    }
    guard isToolMissing else { return nil }
    return SettingsFootnote(
      text: "\(manifest.name) needs the \(requiredTool.displayName) binary, which is not "
        + "downloaded yet.",
      symbol: "arrow.down.circle",
      tone: .warning
    )
  }

  private func refresh() async {
    guard let manifest, let store = model.settingsStore else {
      missing = []
      return
    }
    missing = await ServiceSettingsBridge.missingRequiredFields(manifest, store: store)
  }
}

/// The same form the service's own page shows, in a sheet.
///
/// Literally the same view — not a second copy of the fields. Two renderings of one manifest
/// would drift, and the one nobody looks at would be the one that is wrong.
private struct ConfigureSheet: View {
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
      // The form emits sections rather than a scrolling page, so the sheet supplies the
      // scrolling — the same content, laid out for a smaller frame.
      ScrollView {
        ServiceFormView(manifest: manifest, store: store)
          .padding(20)
      }
    }
    .frame(width: 620, height: 560)
  }
}
