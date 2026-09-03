//  FeatureListing
//  The order and grouping the features screen draws, as data.
//
//  Off the view for the reason `SettingsTabs` and `WebhookEventCatalog` are: this package
//  cannot unit-test an executable target, so anything living in `BlueBubblesApp` is asserted
//  by nobody. What is here instead is every decision worth getting wrong — which groups
//  appear, in what order, what each heading says, and where a collapsed list is cut. The view
//  maps these to rows and owns nothing but symbols and spacing.
//
//  The cut is the subtle one. It counts FEATURES, not entries, so headings do not eat the
//  budget; and it never ends on a heading, because a list that stops immediately after
//  "Also needs a newer macOS" promises a group and then shows none of it.

import Foundation

/// Why a feature is or is not available, which is what decides how a row is drawn.
public enum FeatureAvailability: Sendable, Hashable {
  case available
  /// Present on this macOS, but the Private API is not set up.
  case needsPrivateAPI
  /// Would need a macOS upgrade, whatever else is true.
  case needsNewerMacOS
}

/// One line of the features card.
public enum FeatureListEntry: Sendable, Identifiable, Hashable {
  /// A group heading. `isProminent` marks the ones that are a call to action rather than a
  /// category — those get a symbol and full-strength text.
  case heading(String, isProminent: Bool)
  case feature(PrivateAPICapability, FeatureAvailability)
  /// A rule between two blocks. Here rather than in the view because where one block ends
  /// and another begins is a fact about the list, not a decision about spacing.
  case separator
  /// A line explaining the block that follows.
  case note(String)

  public var id: String {
    switch self {
    case .heading(let text, _): "heading:\(text)"
    case .feature(let capability, _): "feature:\(capability.id)"
    case .separator: "separator"
    case .note(let text): "note:\(text)"
    }
  }

  public var isFeature: Bool {
    if case .feature = self { return true }
    return false
  }
}

extension PrivateAPICapability {

  /// The categories present in a set, in declaration order.
  public static func grouped(
    _ capabilities: [PrivateAPICapability]
  ) -> [(category: Category, capabilities: [PrivateAPICapability])] {
    Category.allCases.compactMap { category in
      let members = capabilities.filter { $0.category == category }
      return members.isEmpty ? nil : (category, members)
    }
  }

  /// The whole card, in order.
  ///
  /// Two different lists, because the two states answer different questions. Connected, it is
  /// "what can I do" — what works, then what an upgrade would add. Not connected, it is "what
  /// am I missing", which is everything, split at this Mac's macOS so the half that also
  /// needs an upgrade is not promised alongside the half that does not.
  public static func listing(
    macOSMajor: Int, privateAPIConnected: Bool
  ) -> [FeatureListEntry] {
    var entries: [FeatureListEntry] = []
    let reachable = all.available(on: macOSMajor)

    if !privateAPIConnected {
      entries.append(.heading("Set up the Private API to unlock", isProminent: true))
    }
    for group in grouped(reachable) {
      entries.append(.heading(group.category.rawValue, isProminent: false))
      entries += group.capabilities.map {
        .feature($0, privateAPIConnected ? .available : .needsPrivateAPI)
      }
    }

    if privateAPIConnected {
      let upgrades = all.upgradePaths(from: macOSMajor)
      for (index, upgrade) in upgrades.enumerated() {
        entries.append(.separator)
        // Said once, above the first group, and only when there is more than one — with a
        // single upgrade there is no order to explain. It carries two facts a reader
        // otherwise has to infer: which way the list runs, and that the groups are
        // INCREMENTAL. Without the second half, someone skimming the top group reads it as
        // everything that release offers.
        if index == 0 && upgrades.count > 1 {
          entries.append(
            .note("Newest first. Upgrading to the one at the top includes everything below it."))
        }
        entries.append(
          .heading("Upgrade to \(releaseName(upgrade.macOS)) to add", isProminent: true))
        entries += upgrade.capabilities.map { .feature($0, .needsNewerMacOS) }
      }
    } else {
      let alsoNeedsUpgrade = all.unavailable(on: macOSMajor)
      if !alsoNeedsUpgrade.isEmpty {
        entries.append(.separator)
        entries.append(.heading("Also needs a newer macOS", isProminent: true))
        entries += alsoNeedsUpgrade.map { .feature($0, .needsNewerMacOS) }
      }
    }
    return entries
  }
}

extension Array where Element == FeatureListEntry {

  /// How many features this listing holds.
  public var featureCount: Int { count { $0.isFeature } }

  /// The first `limit` features, with their headings, never ending on anything but a feature.
  ///
  /// Returns the whole list when it already fits, so a caller can compare counts to decide
  /// whether there is anything to expand.
  public func collapsed(toFeatures limit: Int) -> [FeatureListEntry] {
    guard featureCount > limit else { return self }
    var shown: [FeatureListEntry] = []
    var features = 0
    for entry in self {
      if entry.isFeature {
        if features == limit { break }
        features += 1
      }
      shown.append(entry)
    }
    while let last = shown.last, !last.isFeature { shown.removeLast() }
    return shown
  }
}
