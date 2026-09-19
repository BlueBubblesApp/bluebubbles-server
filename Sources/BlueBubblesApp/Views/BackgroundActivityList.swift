//  BackgroundActivityList
//  The background-task section at the foot of the sidebar, above the server's own status.
//
//  Above rather than below, because the server row is the stable one: it is always there, it
//  is what someone looks for, and a fixed thing should not move because a transient thing
//  appeared under it. Growing upward keeps the Start/Stop button in the same place.
//
//  Absent entirely when nothing is running. A section that is always present but usually empty
//  teaches people to stop looking at it.

import SwiftUI

struct BackgroundActivityList: View {

  @Bindable var model: AppModel

  /// Beyond this the sidebar footer starts eating the sidebar. Four is more than has ever
  /// been in flight at once in practice; the rest are counted rather than dropped.
  private static let visibleLimit = 4

  var body: some View {
    let activities = model.backgroundActivities
    if !activities.isEmpty {
      VStack(alignment: .leading, spacing: 9) {
        Divider()
        HStack(spacing: 6) {
          Text("Background")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .kerning(0.5)
          Spacer()
          // The count earns its place only when some rows are hidden.
          if activities.count > Self.visibleLimit {
            Text("\(activities.count)")
              .font(.caption2.weight(.medium))
              .foregroundStyle(.tertiary)
              .monospacedDigit()
          }
        }

        ForEach(activities.prefix(Self.visibleLimit)) { activity in
          BackgroundActivityRow(activity: activity)
        }

        if activities.count > Self.visibleLimit {
          Text("and \(activities.count - Self.visibleLimit) more")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 12)
      .padding(.top, 2)
      // Room before the server row's own divider, which the sidebar footer stacks directly
      // under this with no spacing of its own, so without this the last progress bar sits
      // flush against the rule above "Running". Roughly matches the 8pt the status bar
      // leaves BELOW that divider, so the rule reads as separating two strips rather than
      // as belonging to the one under it.
      .padding(.bottom, 10)
      // Announced as one group: a row at a time would have VoiceOver read a name, then a
      // bar, then a caption, for each of four tasks.
      .accessibilityElement(children: .combine)
      .accessibilityLabel(BackgroundActivity.announcement(for: activities))
    }
  }
}

/// One task: what it is, how far along, and what it is doing.
private struct BackgroundActivityRow: View {

  let activity: BackgroundActivity

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(activity.name)
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .truncationMode(.tail)

      // Determinate where the task knows its fraction, indeterminate where it does not.
      // Both are the same linear bar so a list of mixed tasks reads as one list.
      if let fraction = activity.fraction {
        ProgressView(value: fraction)
          .progressViewStyle(.linear)
          .controlSize(.small)
      } else {
        ProgressView()
          .progressViewStyle(.linear)
          .controlSize(.small)
      }

      if let detail = activity.detail {
        Text(detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
