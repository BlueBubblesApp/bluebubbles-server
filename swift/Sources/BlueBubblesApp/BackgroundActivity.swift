//  BackgroundActivity
//  What the server is doing right now that nobody asked to watch.
//
//  The sidebar's status strip answers one question (is the server running) and it answers it
//  with one line. That is not enough when several things can be slow at once: a tool
//  downloading, a tunnel signing in, a service restarting after a settings change. Each has
//  its own indicator on its own page, and a 38 MB download in flight should not be visible
//  only from the page that shows it.
//
//  So: one list, on every page, of everything in flight.
//
//  **Derived, never stored.** Every activity below is computed from state the app already
//  observes: tool statuses it streams, service health it polls, its own migration and update
//  models. Nothing reports INTO this and nothing has to remember to clear it, which is the
//  failure mode a mutable registry of "current tasks" always eventually has: a task that ends
//  without saying so leaves a spinner running forever.
//
//  See `.claude/docs/architecture.md`.

import BBServiceKit
import BBTooling
import Foundation

/// One thing happening in the background.
///
/// The name is always there. Beyond that a task either knows how far along it is or it does
/// not, and `State` is that choice rather than two optionals, which is what keeps "no
/// progress and no words", a row that would render as a bare name and tell nobody anything,
/// from being representable at all.
struct BackgroundActivity: Identifiable, Equatable, Sendable {

  enum State: Equatable, Sendable {
    /// Running, with no measurable fraction. The words are the whole report, so they are
    /// required: an indeterminate bar with no caption says only "something is happening".
    case describing(String)
    /// A measured fraction from 0 to 1, with optional words alongside. The fraction is the
    /// report; the detail adds to it and may be absent.
    case measuring(fraction: Double, detail: String?)
  }

  let id: String
  /// What is happening, named for the thing it is happening to: "cloudflared", "Tailscale",
  /// "Contacts". Not a verb phrase: the state below supplies the verb.
  let name: String
  let state: State

  /// 0…1 when this task knows how far along it is.
  var fraction: Double? {
    if case .measuring(let fraction, _) = state { return fraction }
    return nil
  }

  /// The words, if this task has any. Always present for an indeterminate task.
  var detail: String? {
    switch state {
    case .describing(let text): text
    case .measuring(_, let detail): detail
    }
  }

  /// One sentence covering everything in flight, for VoiceOver and for a tooltip.
  ///
  /// On the model rather than on the view that shows it, because two views show it (the
  /// sidebar list and the toolbar indicator) and because a `View`'s statics are main-actor
  /// isolated, which makes a pure string function needlessly awkward to call and to test.
  static func announcement(for activities: [BackgroundActivity]) -> String {
    guard !activities.isEmpty else { return "" }
    let parts = activities.map { activity -> String in
      if let fraction = activity.fraction {
        return "\(activity.name), \(Int(fraction * 100)) percent"
      }
      return "\(activity.name), \(activity.detail ?? "working")"
    }
    return "Background tasks: " + parts.joined(separator: ". ")
  }
}

extension AppModel {

  /// Everything in flight, in a stable order.
  ///
  /// Computed rather than cached: `@Observable` re-reads this whenever any of the state it
  /// touches changes, so there is no second copy to drift and nothing to invalidate. The
  /// order is by category and then by name, so a row does not jump under the cursor when an
  /// unrelated task starts.
  var backgroundActivities: [BackgroundActivity] {
    var found: [BackgroundActivity] = []

    // 1. Tool installs. The only source with a real fraction, and the one most worth
    //    showing: cloudflared is 19 MB compressed and a slow connection makes it a minute
    //    of apparently nothing happening.
    for status in toolStatusList.sorted(by: { $0.id < $1.id }) {
      guard let summary = status.activitySummary, status.activity != .idle else { continue }
      // A failed install is not in flight. It is reported by the page that started it and
      // by an alert; a permanent row in a list of running work would be neither.
      if case .failed = status.activity { continue }
      found.append(
        BackgroundActivity(
          id: "tool.\(status.id)",
          name: status.descriptor.displayName,
          state: status.downloadFraction.map {
            .measuring(fraction: $0, detail: summary)
          } ?? .describing(summary)
        ))
    }

    // 2. The connection method, which has its own richer notion of "not yet": signing in,
    //    waiting for a person, applying a configuration.
    if let activity = connectionActivity, activity.isInProgress {
      found.append(
        BackgroundActivity(
          id: "connection",
          name: activity.method,
          state: .describing(activity.detailOrDefault)
        ))
    }

    // 3. Any other service still starting. The connection method is excluded because the
    //    entry above describes it better: without that, choosing a tunnel showed the same
    //    work twice, once with a reason and once without.
    for (id, health) in serviceHealths.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
      guard case .starting = health else { continue }
      guard id.rawValue != integrations.selectedConnectionMethod else { continue }
      let name = IntegrationCatalog.manifest(id)?.name ?? id.shortName
      found.append(
        BackgroundActivity(
          id: "service.\(id.rawValue)",
          name: name,
          state: .describing("Starting…")
        ))
    }

    // 4. A migration step the user pressed a button for. Long, and the button that started
    //    it is behind a sheet they may have closed.
    if migration.isWorking {
      found.append(
        BackgroundActivity(
          id: "migration",
          name: "Migration",
          state: .describing("Importing from your Electron install…")
        ))
    }

    // 5. The update check, which reaches the network and can hang on a bad connection.
    if updates.state == .checking {
      found.append(
        BackgroundActivity(
          id: "updates",
          name: "Updates",
          state: .describing("Checking for a new version…")
        ))
    }

    return found
  }
}

extension ConnectionActivity {
  /// The reason, or a plain fallback: never empty, because `BackgroundActivity.describing`
  /// is the state that promises words.
  var detailOrDefault: String {
    switch self {
    case .reconnecting(_, let detail):
      detail.isEmpty ? "Reconnecting…" : detail
    case .connected: "Connected"
    case .unavailable(_, let reason): reason
    case .failed(_, let reason): reason
    }
  }
}
