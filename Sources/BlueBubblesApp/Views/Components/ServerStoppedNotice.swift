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

  /// The words are the phase's (`ServerAvailability.swift`): during a start they say the
  /// server is coming up, because a settings tab draws live rows above this notice while
  /// the server waits out its start delay.
  private var phase: ServerPhase { model.phase }

  var body: some View {
    switch placement {
    case .page(let symbol):
      ContentUnavailableView {
        Label(phase.unavailableHeadline, systemImage: symbol)
      } description: {
        Text(phase.unavailableExplanation(purpose: purpose))
      } actions: {
        startButton
      }

    case .section(let title):
      SettingsSection(title, subtitle: phase.unavailableExplanation(purpose: purpose)) {
        Label(phase.unavailableDetail, systemImage: "info.circle")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.vertical, 4)
      } trailing: {
        startButton
      }

    case .card:
      GlassCard {
        HStack(spacing: 12) {
          Label(phase.unavailableExplanation(purpose: purpose), systemImage: "info.circle")
            .font(.subheadline)
          Spacer()
          startButton
        }
      }
    }
  }

  /// The same decision the status bar makes: in `.migrationRequired` the useful action is
  /// to re-open the migration sheet, because starting is exactly what has been refused.
  @ViewBuilder
  private var startButton: some View {
    if phase.isComingUp {
      // The start is already under way; a disabled Start would read as refused.
      ProgressView().controlSize(.small)
    } else {
      startButtonControl
    }
  }

  private var startButtonControl: some View {
    Button("Start Server") {
      Task {
        switch model.phase {
        case .migrationRequired: model.migration.present()
        default: model.beginStart()
        }
      }
    }
    .disabled(model.phase.isBusy)
    // Glass only where the button floats on the window: the `.page` placement. In a
    // section or a card it is on glass already, and bordered is the right style there.
    .prominentGlassButton(when: isPage)
  }

  private var isPage: Bool {
    if case .page = placement { return true }
    return false
  }
}
