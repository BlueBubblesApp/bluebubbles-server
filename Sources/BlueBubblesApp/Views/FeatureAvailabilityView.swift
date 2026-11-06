//  FeatureAvailabilityView
//  What iMessage features this Mac can do, and what would unlock the rest.
//
//  ENTIRELY DERIVED from `PrivateAPICapability.all`. Nothing here names a feature, a version
//  or a count: add a capability to the catalog and it appears in the right group, under the
//  right heading, with no view edited. That is the point: the list will keep growing, and a
//  screen that has to be updated alongside it is a screen that will eventually be wrong.
//
//  TWO THINGS GATE A FEATURE, and the difference decides what this screen is for:
//
//     the Private API   off or not injected, and NONE of this works: every capability
//                       here goes through the helper. Fixable by the user, today.
//     the macOS version fixable only by upgrading, and sometimes not worth it.
//
//  So it renders two different pages. With the helper connected it answers "what can I do",
//  which is a list of what works and what a newer macOS would add. Without it, it answers
//  "what am I missing", which is the whole catalog, because that is what setting the Private
//  API up would buy, and a page that just said "not connected" would be hiding the reason
//  anyone would bother.
//
//  The vocabulary is deliberately the user's, not this codebase's. Somebody reading this is
//  deciding whether to set the Private API up or upgrade macOS: they are not looking up a
//  selector. The catalog's copy is checked by a test for exactly that, so a class name cannot
//  reach this screen even by accident.
//
//  What is NOT here, also deliberately: anything this port has laddered onto an older
//  spelling. Those work on every supported release, so they are not something an upgrade
//  buys, and listing them would advertise one that gains nothing.

import BBPrivateAPI
import BBPrivateAPICatalog
import SwiftUI

struct FeatureAvailabilityView: View {
  let model: AppModel

  /// The state this card decided to draw, published back up so the rest of the page agrees
  /// with it: the SIP note and the connection status card are both shown or hidden on it.
  ///
  /// Written from the model's followed state, so the parent draws the notes below this
  /// card for the same state the card shows.
  @Binding var presence: PrivateAPIPresence

  var body: some View {
    SettingsSection(title, subtitle: subtitle) {
      CollapsibleFeatureList(entries: entries)
        // The Private API coming up mid-session swaps one list for a different one, so the
        // fold resets rather than carrying over how far the previous list had been opened.
        .id(listIdentity)
    } trailing: {
      trailing
    }
    .onChange(of: model.privateAPIPresence, initial: true) { _, value in
      presence = value
    }
  }

  // MARK: - What state to draw

  private var isConnected: Bool { model.privateAPIPresence.showsAvailableFeatures }

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

  private var trailing: some View {
    Text(PrivateAPICapability.releaseName(macOSMajor))
      .font(.subheadline.weight(.medium))
      .foregroundStyle(.secondary)
  }
}
