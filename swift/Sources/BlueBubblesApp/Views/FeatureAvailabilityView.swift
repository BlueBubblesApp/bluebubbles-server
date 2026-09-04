//  FeatureAvailabilityView
//  What iMessage features this Mac can do, and what would unlock the rest.
//
//  ENTIRELY DERIVED from `PrivateAPICapability.all`. Nothing here names a feature, a version
//  or a count — add a capability to the catalog and it appears in the right group, under the
//  right heading, with no view edited. That is the point: the list will keep growing, and a
//  screen that has to be updated alongside it is a screen that will eventually be wrong.
//
//  TWO THINGS GATE A FEATURE, and the difference decides what this screen is for:
//
//     the Private API   off or not injected, and NONE of this works — every capability
//                       here goes through the helper. Fixable by the user, today.
//     the macOS version fixable only by upgrading, and sometimes not worth it.
//
//  So it renders two different pages. With the helper connected it answers "what can I do",
//  which is a list of what works and what a newer macOS would add. Without it, it answers
//  "what am I missing", which is the whole catalog — because that is what setting the Private
//  API up would buy, and a page that just said "not connected" would be hiding the reason
//  anyone would bother.
//
//  The vocabulary is deliberately the user's, not this codebase's. Somebody reading this is
//  deciding whether to set the Private API up or upgrade macOS — they are not looking up a
//  selector. The catalog's copy is checked by a test for exactly that, so a class name cannot
//  reach this screen even by accident.
//
//  What is NOT here, also deliberately: anything this port has laddered onto an older
//  spelling. Those work on every supported release, so they are not something an upgrade
//  buys, and listing them would advertise one that gains nothing.

import BBCapabilities
import BBPrivateAPI
import SwiftUI

struct FeatureAvailabilityView: View {
  let model: AppModel

  /// The state this card decided to draw, published back up so the rest of the page agrees
  /// with it — the SIP note and the connection status card are both shown or hidden on it.
  ///
  /// A binding rather than a second poll in the parent: two pollers is two answers to one
  /// question, and they would disagree for whole seconds during startup — the page would
  /// show the features card for one state and the notes below it for another.
  @Binding var presence: PrivateAPIPresence

  /// The live answer, polled the same way the status card polls it.
  @State private var livePresence: PrivateAPIPresence = .connected
  /// Nil until the first poll lands, so the card does not flash "you are missing everything"
  /// during the second before the runtime answers.
  @State private var hasPolled = false

  var body: some View {
    SettingsSection(title, subtitle: subtitle, trailing: trailing) {
      CollapsibleFeatureList(entries: entries)
        // The Private API coming up mid-session swaps one list for a different one, so the
        // fold resets rather than carrying over how far the previous list had been opened.
        .id(listIdentity)
    }
    .onChange(of: effectivePresence, initial: true) { _, value in
      presence = value
    }
    .task {
      // Polled rather than observed, for the reason `PrivateAPIStatusCard` gives: the
      // runtime is an actor behind the server and these states change over seconds during
      // startup. Same cadence, so the two cards never disagree on screen.
      while !Task.isCancelled {
        await refresh()
        try? await Task.sleep(for: .seconds(3))
      }
    }
  }

  private func refresh() async {
    guard let runtime = await model.privateAPIAccess?.privateAPIRuntime else {
      livePresence = .notEnabled
      hasPolled = true
      return
    }
    // Two awaits, not one expression: an actor's properties cannot both be read inside one
    // autoclosing operator.
    let outcome = await runtime.startOutcome
    let connected = await runtime.isConnected
    livePresence = PrivateAPIPresence(outcome: outcome, isConnected: connected)
    hasPolled = true
  }

  // MARK: - What state to draw

  /// Treated as connected until the first poll answers, so the page does not accuse the user
  /// of a broken setup for the second before it knows.
  private var effectivePresence: PrivateAPIPresence {
    hasPolled ? livePresence : .connected
  }

  private var isConnected: Bool { effectivePresence.showsAvailableFeatures }

  private var macOSMajor: Int { PrivateAPICapability.currentMacOSMajor }

  private var upgrades: [(macOS: Int, capabilities: [PrivateAPICapability])] {
    PrivateAPICapability.all.upgradePaths(from: macOSMajor)
  }

  private var entries: [FeatureListEntry] {
    PrivateAPICapability.listing(macOSMajor: macOSMajor, privateAPIConnected: isConnected)
  }

  private var listIdentity: String { "\(macOSMajor)-\(isConnected)" }

  private var title: String {
    isConnected ? "iMessage features" : "What the Private API adds"
  }

  private var subtitle: String {
    guard isConnected else {
      return
        "None of these work until the Private API is set up. It is what lets this server "
        + "reach the parts of iMessage Apple does not expose."
    }
    return upgrades.isEmpty
      ? "Everything this server supports is available on your Mac."
      : "Everything below works today. Further down is what a newer macOS would add."
  }

  private var trailing: AnyView? {
    AnyView(
      Text(PrivateAPICapability.releaseName(macOSMajor))
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary))
  }
}

// MARK: - Collapsing

/// The list, cut to a readable length until asked for the rest.
///
/// Twenty-one features is a correct answer and a bad card: a settings page that opens with a
/// full screen of list buries the controls underneath it. So it shows a few and says how many
/// more there are.
///
/// The cut is a ROW COUNT rather than a height, so it survives a larger text size — a fixed
/// `maxHeight` would clip mid-word for anyone not using the default. Where to cut is decided
/// by `collapsed(toFeatures:)`, which is in `BBCapabilities` because it has an edge case
/// worth a test and this target has none.
private struct CollapsibleFeatureList: View {
  let entries: [FeatureListEntry]
  /// How many FEATURES to show collapsed. Headings are free — they are what makes the
  /// visible part make sense.
  var limit: Int = 6

  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(visible) { entry in
          switch entry {
          case .heading(let text, let isProminent):
            HeadingRow(text: text, isProminent: isProminent)
          case .feature(let capability, let availability):
            FeatureRow(capability: capability, availability: availability)
          case .separator:
            SettingsDivider()
          case .note(let text):
            Text(text)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      // Only a collapsed list fades. Masking an expanded one would dim its last row for no
      // reason, and the fade is the signal that something is hidden.
      .mask(fadeMask)

      if hiddenCount > 0 || isExpanded {
        Button {
          withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
          Label(
            isExpanded ? "Show less" : "Show \(hiddenCount) more",
            systemImage: isExpanded ? "chevron.up" : "chevron.down"
          )
          .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.link)
        .padding(.top, 12)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 4)
  }

  private var visible: [FeatureListEntry] {
    isExpanded ? entries : entries.collapsed(toFeatures: limit)
  }

  private var hiddenCount: Int { entries.featureCount - visible.featureCount }

  @ViewBuilder private var fadeMask: some View {
    if isExpanded || hiddenCount == 0 {
      Rectangle()
    } else {
      // Fades the last rows rather than cutting them off square: a hard edge at a group
      // boundary reads as the end of the list rather than a fold in it. Stops short of
      // fully transparent so the final row stays legible enough to be worth reading.
      LinearGradient(
        stops: [
          .init(color: .black, location: 0),
          .init(color: .black, location: 0.72),
          .init(color: .black.opacity(0.12), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
  }
}

// MARK: - Rows

private struct HeadingRow: View {
  let text: String
  let isProminent: Bool

  var body: some View {
    HStack(spacing: 8) {
      if isProminent {
        Image(systemName: "arrow.up.circle.fill").foregroundStyle(.tint)
      }
      Text(text)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isProminent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }
    .padding(.top, 4)
  }
}

private struct FeatureRow: View {
  let capability: PrivateAPICapability
  let availability: FeatureAvailability

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // A distinct glyph per state, not colour alone — the difference between these rows has
      // to survive being read by somebody who cannot tell green from grey.
      Image(systemName: symbol)
        .foregroundStyle(isDimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(capability.title)
          .font(.body)
          .foregroundStyle(isDimmed ? .secondary : .primary)
        Text(capability.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(capability.title). \(capability.summary) \(accessibilitySuffix)")
  }

  private var symbol: String {
    switch availability {
    case .available: "checkmark.circle.fill"
    case .needsPrivateAPI: "lock.circle"
    case .needsNewerMacOS: "arrow.up.circle"
    }
  }

  private var isDimmed: Bool { availability != .available }

  private var accessibilitySuffix: String {
    switch availability {
    case .available: "Available on this Mac."
    case .needsPrivateAPI: "Needs the Private API to be set up."
    case .needsNewerMacOS:
      "Needs \(PrivateAPICapability.releaseName(capability.minimumMacOS))."
    }
  }
}
