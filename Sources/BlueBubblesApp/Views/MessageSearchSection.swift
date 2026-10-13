//  MessageSearchSection
//  The message search index: the switch, what it is doing, and the one action that is not a
//  setting.
//
//  **The switch is drawn HERE, not by the generated page.** It is `isInternal`, listed by
//  `MessageSearchPanel`, and rendered with the same `SettingRow` every other setting uses,
//  so there is one description of it rather than two. Left to the generated page it was a
//  row in Features between Startup Delay and Hide Dock Icon, with the state it turns on in
//  a separate section further down the tab.
//
//  What a declaration cannot express is STATE: a backfill that is still running, a count
//  worth seeing, or a Mac whose SQLite cannot hold an index at all. Those need a reader,
//  which is the rest of this. The status card appears only once the feature is on, the rule
//  `GroupChatShortcutSection` follows: with it off, the switch above it already says so.
//
//  IT READS THE STORE, NOT THE SERVICE. What a person wants to know here is the state of the
//  index — does it exist, is it finished, how much is in it — and that lives in the file. The
//  app has no business looking up a concrete service either: the registry owns services, not
//  the other way round. Rebuilding is the same shape, a flag the indexer acts on rather than
//  a restart this screen orders.

import BBBuiltIns
import BBCore
import BBIMessage
import BBServiceKit
import BBSettings
import BlueBubblesServerCore
import SwiftUI

struct MessageSearchSection: View {

  @Bindable var model: AppModel

  /// Nil until the setting has been read, so the status card does not flash in and out on
  /// a server that has it off.
  @State private var isEnabled: Bool?
  @State private var status: Status?
  @State private var isRebuilding = false

  /// What the index is, as a screen needs to say it.
  ///
  /// Derived from the store rather than mirrored from the service, so there is no second
  /// copy of the truth to go stale.
  enum Status: Equatable {
    /// SQLite here is too old. Nothing to do about it, so the row explains instead of
    /// offering an action.
    case unsupported(reason: String)
    case building(indexed: Int)
    case ready(indexed: Int)
    /// The store would not answer. Its own state rather than a count of zero: "0 messages
    /// so far" over a read that failed reads as an index that has not started.
    case unreadable(String)
  }

  var body: some View {
    section
      .task(id: RefreshKey(model)) { await refresh() }
  }

  /// What makes this section read the store again.
  ///
  /// The server phase, so starting the server re-reads rather than leaving whatever was on
  /// screen when it was stopped — the rule `ScreenReloadPolicyTests` enforces.
  ///
  /// **And the indexer's own health, which is the half that was missing.** The interesting
  /// change here happens entirely inside the service, seconds to minutes after this view
  /// appeared: a backfill walking the table while the count climbs. Keyed on the phase
  /// alone, "Building the index… 0 messages so far" sat at zero for the whole run unless
  /// the user navigated away and back, and the report the service sends on every page —
  /// `setState` calling `serviceHealthDidChange()`, built for exactly this — reached
  /// nobody: the Integrations screen filters on `isUserManageable`, which this manifest
  /// sets false, and the sidebar's background list did not list a degraded service. It
  /// does since the health carries the walk's fraction; see `BackgroundActivity.forService`.
  ///
  /// The health is the TRIGGER, not the content: what gets rendered is read back from the
  /// file. The reason the health carries a count at all is so this key changes.
  private struct RefreshKey: Equatable {
    let isRunning: Bool
    let indexerHealth: ServiceHealth?

    @MainActor init(_ model: AppModel) {
      isRunning = model.phase.isRunning
      indexerHealth = model.serviceHealth(BuiltInManifests.ID.messageSearch)
    }
  }

  private var section: some View {
    // The section is the card: a `GlassCard` inside it would be glass sampling glass.
    SettingsSection("Message Search", subtitle: Self.subtitle) {
      VStack(alignment: .leading, spacing: SettingsMetrics.cardStackSpacing) {
        ForEach(MessageSearchPanel.settings, id: \.id) { setting in
          SettingRow(setting: setting, model: model)
        }
        if isEnabled == true {
          Divider()
          statusLine
          if case .ready = status {
            Divider()
            rebuildRow
          }
        }
      }
      .padding(.vertical, 2)
    } trailing: {
      if isEnabled == true, status == nil {
        Text("Reading…").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private static let subtitle =
    "Recent versions of macOS stopped storing the words of a message where other apps can "
    + "read them, so searching message text finds almost nothing. An index on this Mac "
    + "answers those searches: it holds which words appear in which message, never the "
    + "messages themselves."

  @ViewBuilder private var statusLine: some View {
    switch status {
    case nil:
      // Said out loud rather than shown as an empty row. A section that reads from the
      // server has to admit when it is reading; see `ScreenLoadingStatePolicyTests`.
      Label("Reading the index…", systemImage: "clock")
        .font(.callout).foregroundStyle(.secondary)

    case .unsupported(let reason):
      VStack(alignment: .leading, spacing: 4) {
        Label("Not available on this Mac", systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.secondary)
        Text(reason).font(.caption).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)

    case .building(let indexed):
      VStack(alignment: .leading, spacing: 4) {
        Label("Building the index…", systemImage: "arrow.triangle.2.circlepath")
          .font(.callout)
        // A count rather than a bar. The sidebar has the bar, drawn from the service's
        // health, where the walk's extent is known; this section reads the store, which
        // holds the count and no extent, and a bar against a total re-read from a live
        // database reaches 100% and keeps going, which is worse than no bar.
        Text(
          "\(indexed.formatted()) messages so far. Searching works, but will not find "
            + "everything until this finishes."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)

    case .ready(let indexed):
      Label(
        "\(indexed.formatted()) messages indexed", systemImage: "checkmark.circle.fill"
      )
      .font(.callout).foregroundStyle(.secondary)

    case .unreadable(let reason):
      VStack(alignment: .leading, spacing: 4) {
        Label("The index could not be read", systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.secondary)
        Text(reason).font(.caption).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    }
  }

  private var rebuildRow: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Rebuild").font(.callout)
        Text(
          "Reads your history again from the beginning. Worth doing if search starts "
            + "missing things; it takes about a minute and search keeps working meanwhile."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 16)
      Button("Rebuild") { Task { await rebuild() } }
        .disabled(isRebuilding)
    }
  }

  // MARK: - Reading

  private func refresh() async {
    let enabled: Bool
    do {
      enabled = try await model.settings.get(Settings.searchIndexEnabled)
    } catch {
      // `ServerNotRunning`: there is no index to report on, and the settings page around
      // this section is already showing the stopped notice in its place.
      isEnabled = nil
      status = nil
      return
    }
    isEnabled = enabled
    guard enabled, let index = model.messaging.searchIndex else {
      status = nil
      return
    }
    if case .unsupported(let reason) = await index.lastAvailability {
      status = .unsupported(reason: reason)
      return
    }
    // A read that fails says so. It used to be `try?` to false and zero, which drew a
    // healthy-looking "0 messages so far" over a store that would not answer.
    do {
      let complete = try await index.isBackfillComplete()
      let count = try await index.indexedCount()
      status = complete ? .ready(indexed: count) : .building(indexed: count)
    } catch {
      status = .unreadable(DiagnosticText.sentence(for: error))
    }
  }

  private func rebuild() async {
    isRebuilding = true
    defer { isRebuilding = false }
    // A FLAG, not a restart. The indexer notices on its next pass and walks the table
    // again; see `SearchIndexStore.requestRebuild`. A request that could not be made says
    // so where the status is: it was `try?`, and the button did nothing visible.
    do {
      try await model.messaging.searchIndex.orServerNotRunning().requestRebuild()
    } catch {
      status = .unreadable(DiagnosticText.sentence(for: error))
      return
    }
    await refresh()
  }
}
