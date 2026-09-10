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
//  One button, named after the thing it configures. A second button opening the service's
//  page would sit a step apart in specificity from "Configure…", and the difference is not
//  something a reader can infer.
//
//  See `.claude/docs/architecture.md`.

import AppKit
import BBBuiltIns
import BBDiagnostics
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
    IntegrationCatalog.manifest(ServiceIdentifier(selection))
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
  /// a binary the user pointed at themselves as well as a managed install, which a check
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

  /// What the chosen method is waiting on a PERSON for: a sign-in, an approval, a feature
  /// to switch on. The third kind of "still needs something", beside a blank field and a
  /// missing binary, and for Tailscale the only kind, since every field is optional and
  /// the binary downloads in one click, so without it the row read as complete while the
  /// tunnel sat waiting for a link nobody had opened.
  private var pendingAttention: [UserAlert] {
    guard let manifest else { return [] }
    return model.alerts.pendingAttention(for: manifest.id)
  }

  /// The first link among the pending steps, for the button.
  private var pendingLink: URL? {
    for alert in pendingAttention {
      for action in alert.actions {
        if case .openURL(let url) = action { return url }
      }
    }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      SettingsRow(
        title: setting.presentation.label,
        help: setting.presentation.help,
        // The specific thing that is missing, named. "ngrok needs an Auth Token" is
        // actionable; "not configured" sends someone hunting.
        footnotes: ([missingNote, toolNote, stateNote] + attentionNotes).compactMap { $0 }
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
          // The step's link, where the step is reported. Marked read on use, as the
          // drawer does; withdrawn by the service once the step is taken.
          if let pendingLink, let alert = pendingAttention.first {
            Button("Open Link") {
              NSWorkspace.shared.open(pendingLink)
              Task { await model.alerts.setRead(alert.id, true) }
            }
            .buttonStyle(.borderedProminent)
          }
          Button("Configure \(manifest.name)") { isConfiguring = true }
          Spacer()
        }
        // These buttons hang BELOW the `SettingsRow`, which is what carries the row rhythm,
        // so they fell outside it and sat flush against the next divider, reading as
        // though they belonged to the setting underneath. Half the row spacing, matching
        // what `SettingsRow` puts below its own content.
        .padding(.bottom, SettingsMetrics.rowSpacing / 2)
      }
    }
    .task(id: selection) { await refresh() }
    .sheet(isPresented: $isConfiguring) {
      if let manifest, let store = model.settingsStore {
        ConfigureSheet(
          manifest: manifest, store: store, model: model,
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

  /// What the chosen method is doing right now, from the registry.
  ///
  /// The registry's own words for anything that is not simply running ("waiting for
  /// Tailscale to finish starting", "waiting for you to sign in") because those are the
  /// states in which someone looks at this row wondering what is happening.
  private var stateNote: SettingsFootnote? {
    guard let manifest, let health = model.serviceHealth(manifest.id) else { return nil }

    // BEFORE the health switch, and asked of the app's own state rather than read out of
    // the registry's sentence: the same move `connectionActivity` makes, for the same
    // reason. A method stranded by a switched-off dependency reaches this row as
    // `inactive`, which the case below renders with a clock and a neutral tone: the
    // vocabulary of waiting, for a state that resolves only when somebody goes and turns
    // that dependency back on. It also names the dependency, which the registry
    // deliberately will not, and which is the half that makes the sentence actionable.
    if let blocking = model.integrations.disabledDependency(of: manifest) {
      return SettingsFootnote(
        text: "\(manifest.name) is not running: \(blocking.name) is switched off.",
        symbol: "pause.circle", tone: .warning
      )
    }

    switch health {
    case .running:
      return SettingsFootnote(
        text: "\(manifest.name) is connected.", symbol: "checkmark.circle", tone: .neutral
      )
    case .starting:
      return SettingsFootnote(
        text: "\(manifest.name) is starting.", symbol: "clock", tone: .neutral
      )
    case .stopped:
      return SettingsFootnote(
        text: "\(manifest.name) is not running.", symbol: "pause.circle", tone: .warning
      )
    case .inactive(let reason):
      return SettingsFootnote(
        text: "\(manifest.name): \(reason).", symbol: "clock", tone: .neutral
      )
    case .degraded(let reason):
      return SettingsFootnote(
        text: "\(manifest.name) is connected but \(reason).",
        symbol: "exclamationmark.circle", tone: .warning
      )
    case .failed(let reason):
      return SettingsFootnote(
        text: "\(manifest.name) failed: \(reason).", symbol: "xmark.circle", tone: .error
      )
    }
  }

  /// One note per pending step, in the step's own words.
  private var attentionNotes: [SettingsFootnote?] {
    pendingAttention.map { alert in
      SettingsFootnote(
        text: alert.title + ". " + alert.body,
        symbol: "person.crop.circle.badge.exclamationmark",
        tone: .warning
      )
    }
  }

  /// The same treatment a missing token gets, for a missing binary.
  ///
  /// Without it, choosing ngrok looks complete (the picker shows ngrok, no field is blank)
  /// and the tunnel then fails to start with the reason only in the log. A binary that has
  /// not been downloaded is a required thing that is missing, exactly like an empty auth
  /// token.
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
/// Literally the same view: not a second copy of the fields. Two renderings of one manifest
/// would drift, and the one nobody looks at would be the one that is wrong.
private struct ConfigureSheet: View {
  let manifest: ServiceManifest
  let store: SettingsStore
  let model: AppModel
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
      // scrolling: the same content, laid out for a smaller frame.
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          // The address FIRST, in the sheet as on the page: the sheet is where someone
          // changes the field and watches for what it did.
          PublishedAddressSection(manifest: manifest, model: model)
          ServiceFormView(manifest: manifest, store: store, model: model)
        }
        .padding(20)
      }
    }
    .frame(minWidth: 520, idealWidth: 620, minHeight: 440, idealHeight: 560)
  }
}
