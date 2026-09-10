//  BackgroundActivityIndicator
//  A spinner in the toolbar while anything is running in the background.
//
//  The sidebar carries the full list, and the sidebar can be collapsed, so this is the same
//  fact in the one place that is on screen in every layout. Driven by the SAME derivation as
//  the list rather than by its own reading of the state, because two definitions of "busy"
//  disagreeing in the corner of the window is worse than not having the second one.
//
//  Empty when nothing is happening: the indicator's whole value is that its appearance means
//  something.

import SwiftUI

struct BackgroundActivityIndicator: View {

  @Bindable var model: AppModel

  var body: some View {
    let activities = model.backgroundActivities
    if let first = activities.first {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        // One task is named. Several are counted: four names would not fit a toolbar, and
        // the sidebar is where the detail lives.
        Text(activities.count == 1 ? first.name : "\(activities.count) tasks")
          .font(.callout)
      }
      .help(BackgroundActivity.announcement(for: activities))
      .accessibilityLabel(BackgroundActivity.announcement(for: activities))
    } else if case .failed(let method, _) = model.connectionActivity {
      Label("\(method) failed", systemImage: "xmark.circle.fill")
        .font(.callout)
        .foregroundStyle(.red)
        .help(model.connectionActivity?.summary ?? "")
    }
  }
}
