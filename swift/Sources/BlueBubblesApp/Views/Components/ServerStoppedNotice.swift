//  ServerStoppedNotice
//  What a page shows where its content would be, when there is no server to read it from.
//
//  Nine pages said this, each in its own words, and none of them offered the one thing the
//  person needed: the Start button, which sits at the bottom of the sidebar and nowhere near
//  the sentence telling them to press it. One view, one sentence shape, and the remedy on it,
//  the same reasoning as `FeatureDisabledNotice`, which is the sibling for a switched-off
//  feature.
//
//  Three placements, because the pages are three kinds: a page whose whole content is the
//  read (`.page`) stands in for all of it; a section inside a page that otherwise renders
//  (`.section`) stands in for that section alone; and a card at the top of a page whose
//  guidance still reads without a server (`.card`) says only what is missing.
//  `ServerStoppedNoticeTests` refuses a page that writes the sentence itself.

import SwiftUI

struct ServerStoppedNotice: View {

  enum Placement {
    /// The whole page. `symbol` is the page's own, so the empty state reads as the page.
    case page(symbol: String)
    /// One section of a page that otherwise renders, under this heading.
    case section(title: String)
    /// A card above content that still reads without a server: the Guides page.
    case card
  }

  @Bindable var model: AppModel
  let placement: Placement
  /// What starting the server would let the person do, as the tail of "Start the server
  /// to …": "view contacts", "manage webhooks".
  let purpose: String

  var body: some View {
    switch placement {
    case .page(let symbol):
      ContentUnavailableView {
        Label("Server not running", systemImage: symbol)
      } description: {
        Text("Start the server to \(purpose).")
      } actions: {
        startButton
      }

    case .section(let title):
      SettingsSection(title, subtitle: "Start the server to \(purpose).") {
        Label(
          "The server is not running, so there is nothing to show yet.",
          systemImage: "info.circle"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
      } trailing: {
        startButton
      }

    case .card:
      GlassCard {
        HStack(spacing: 12) {
          Label("Start the server to \(purpose).", systemImage: "info.circle")
            .font(.subheadline)
          Spacer()
          startButton
        }
      }
    }
  }

  /// The same decision the status bar makes: in `.migrationRequired` the useful action is
  /// to re-open the migration sheet, because starting is exactly what has been refused.
  private var startButton: some View {
    Button("Start Server") {
      Task {
        switch model.phase {
        case .migrationRequired: model.migration.present()
        default: await model.start()
        }
      }
    }
    .disabled(model.phase.isBusy)
  }
}
