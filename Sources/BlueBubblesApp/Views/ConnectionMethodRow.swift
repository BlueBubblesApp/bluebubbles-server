//  ConnectionMethodRow
//  Choosing a connection method, and getting to its configuration.
//
//  The problem this solves is the one that makes "configure it on its own page" annoying: the
//  user picks ngrok here, ngrok needs an auth token, and nothing on this screen says so or
//  offers a way there. They find out when the tunnel fails to start.
//
//  So the row reports what the CHOSEN method still needs, inline, and resolves it here: the
//  sheet edits the same fields the service's own page does, the download button fetches the
//  binary without leaving, and a step such as a sign-in carries its own link. What is needed
//  is `ConnectionMethodNeeds`, the same answer setup reads; what is compact here is only how
//  much of it is drawn.
//
//  One button, named after the thing it configures. A second button opening the service's
//  page would sit a step apart in specificity from "Configure…", and the difference is not
//  something a reader can infer.
//
//  See `.claude/docs/architecture.md`.

import BBServiceKit
import BBSettings
import SwiftUI

struct ConnectionMethodRow: View {

  let setting: AnySetting
  let selection: String
  let onChange: (String) -> Void

  @Environment(AppModel.self) private var model
  @State private var isConfiguring = false

  private var manifest: ServiceManifest? {
    IntegrationCatalog.manifest(ServiceIdentifier(selection))
  }

  private var needs: ConnectionMethodNeeds? {
    manifest.map { model.connectionNeeds(of: $0) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      SettingsRow(
        title: setting.presentation.label,
        help: setting.presentation.help,
        footnotes: footnotes
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

      if let manifest, let needs {
        VStack(alignment: .leading, spacing: 10) {
          if !needs.steps.isEmpty {
            ConnectionMethodSteps(steps: needs.steps, model: model)
          }
          if needs.canDownloadProgram || !manifest.settings.isEmpty {
            HStack(spacing: 12) {
              // Offered right here rather than only on the service's own page, because this
              // is the moment the person learns they need it.
              if needs.canDownloadProgram, let tool = needs.tool {
                Button("Download \(tool.displayName)") {
                  Task { await model.installTool(tool.id) }
                }
                .buttonStyle(.borderedProminent)
              }
              if !manifest.settings.isEmpty {
                Button("Configure \(manifest.name)") { isConfiguring = true }
              }
              Spacer()
            }
          }
        }
        // These hang BELOW the `SettingsRow`, which is what carries the row rhythm, so they
        // fell outside it and sat flush against the next divider, reading as though they
        // belonged to the setting underneath. Half the row spacing, matching what
        // `SettingsRow` puts below its own content.
        .padding(.bottom, SettingsMetrics.rowSpacing / 2)
      }
    }
    .sheet(isPresented: $isConfiguring) {
      if let manifest {
        ConfigureSheet(
          manifest: manifest, model: model,
          onDone: { isConfiguring = false }
        ) {
          // The address FIRST, in the sheet as on the page: the sheet is where someone
          // changes the field and watches for what it did.
          PublishedAddressSection(manifest: manifest, model: model)
        }
      }
    }
  }

  /// The needs a line can answer for, each under its own kind: a row keys its footnotes by
  /// kind, so two of the same kind would collide and show one of them unpredictably, and a
  /// missing token and a missing program can both be true.
  private var footnotes: [SettingsFootnote] {
    guard let needs else { return [] }
    let lines: [(ServiceStatusSummary.Line?, SettingsFootnote.Kind)] = [
      (needs.fieldsLine, .required),
      (needs.programLine, .advice),
      (needs.statusLine, .status),
    ]
    return lines.compactMap { line, kind in
      line.map { SettingsFootnote(text: $0.text, kind: kind, symbol: $0.symbol, tone: $0.tone) }
    }
  }
}
