//  ConnectionMethodSteps
//  The steps a connection method is waiting on a person for, and the link to take each one.
//
//  One drawing, on every screen that offers a method. It was three: a section on the method's
//  page, footnotes and a single button on the Connection row, and nothing at all in setup,
//  where the bell that also carries these is behind the sheet. The row's button took the first
//  link from any step and marked the first step read, which were not always the same step.
//
//  Which steps there are is `ConnectionMethodNeeds`. A link is drawn only for a step the
//  running service has raised and not withdrawn, so it is never a dead button.

import AppKit
import SwiftUI

struct ConnectionMethodSteps: View {

  let steps: [ConnectionMethodNeeds.Step]
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(steps) { step in
        VStack(alignment: .leading, spacing: 6) {
          Label(step.title, systemImage: "exclamationmark.triangle.fill")
            .font(.body.weight(.medium))
            .foregroundStyle(StatusTone.attention.tint)
          Text(step.body)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          if let link = step.link {
            HStack(spacing: 10) {
              // Marked read on use, as the drawer does; withdrawn by the service once the
              // step is taken.
              Button("Open Link") {
                NSWorkspace.shared.open(link)
                Task { await model.alerts.setRead(step.id, true) }
              }
              .buttonStyle(.borderedProminent)
              // Every step's button has the same name, so say which one this is.
              .accessibilityHint(step.title)
              // Selectable, for a sign-in someone would rather finish on their phone than
              // in this Mac's browser.
              Text(link.absoluteString)
                .font(.caption).foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            }
          }
        }
      }
    }
  }
}

/// The steps as a section of a page, where a page has room for one. Draws nothing while no
/// step is pending, so a screen places it unconditionally.
struct ConnectionMethodAttentionSection: View {

  let needs: ConnectionMethodNeeds
  let model: AppModel

  var body: some View {
    if !needs.steps.isEmpty {
      SettingsSection(
        "Needs Your Attention",
        subtitle: "\(needs.name) cannot finish connecting until this is done."
      ) {
        ConnectionMethodSteps(steps: needs.steps, model: model)
      }
    }
  }
}
