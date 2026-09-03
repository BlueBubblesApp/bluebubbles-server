//  FeatureAvailabilityView
//  What iMessage features this Mac can do, and what a newer macOS would add.
//
//  ENTIRELY DERIVED from `PrivateAPICapability.all`. Nothing here names a feature, a version
//  or a count — add a capability to the catalog and it appears in the right group, under the
//  right release, with no view edited. That is the point: the list will keep growing, and a
//  screen that has to be updated alongside it is a screen that will eventually be wrong.
//
//  The vocabulary is deliberately the user's, not this codebase's. Somebody reading this is
//  deciding whether upgrading macOS is worth it — they are not looking up a selector. The
//  catalog's copy is checked by a test for exactly that (`copyIsPlainLanguage`), so a class
//  name cannot reach this screen even by accident.
//
//  What is NOT here, also deliberately: anything this port has laddered. A feature that works
//  on every supported release through an older spelling is not version-dependent from a
//  user's point of view, and listing it as one would advertise an upgrade that buys nothing.

import BBCapabilities
import SwiftUI

struct FeatureAvailabilityView: View {
  /// Injectable so previews and any future test can render a release this Mac is not.
  var macOSMajor: Int = PrivateAPICapability.currentMacOSMajor

  private var available: [PrivateAPICapability] {
    PrivateAPICapability.all.available(on: macOSMajor)
  }
  private var upgrades: [(macOS: Int, capabilities: [PrivateAPICapability])] {
    PrivateAPICapability.all.upgradePaths(from: macOSMajor)
  }

  var body: some View {
    SettingsSection(
      "iMessage features",
      subtitle: subtitle,
      trailing: AnyView(
        Text(PrivateAPICapability.releaseName(macOSMajor))
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary))
    ) {
      ForEach(Array(grouped(available).enumerated()), id: \.element.category) { index, group in
        if index > 0 { SettingsDivider() }
        CategoryRows(title: group.category.rawValue, capabilities: group.capabilities)
      }

      ForEach(upgrades, id: \.macOS) { upgrade in
        SettingsDivider()
        UpgradeGroup(macOS: upgrade.macOS, capabilities: upgrade.capabilities)
      }
    }
  }

  /// The one sentence that changes with the answer, rather than a fixed line that is wrong
  /// on the newest release.
  private var subtitle: String {
    upgrades.isEmpty
      ? "Everything this server supports is available on your Mac."
      : "Everything below works today. Further down is what a newer macOS would add."
  }

  private func grouped(
    _ capabilities: [PrivateAPICapability]
  ) -> [(category: PrivateAPICapability.Category, capabilities: [PrivateAPICapability])] {
    PrivateAPICapability.Category.allCases.compactMap { category in
      let members = capabilities.filter { $0.category == category }
      return members.isEmpty ? nil : (category, members)
    }
  }
}

/// One category of things that work.
private struct CategoryRows: View {
  let title: String
  let capabilities: [PrivateAPICapability]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      ForEach(capabilities) { capability in
        FeatureRow(capability: capability, isAvailable: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 4)
  }
}

/// What one macOS upgrade would add.
///
/// Grouped by release rather than listed flat, because "what would I get" is answered per
/// upgrade — somebody on macOS 14 needs to see that one step gets them most of it.
private struct UpgradeGroup: View {
  let macOS: Int
  let capabilities: [PrivateAPICapability]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "arrow.up.circle.fill")
          .foregroundStyle(.tint)
        Text("Upgrade to \(PrivateAPICapability.releaseName(macOS)) to add")
          .font(.subheadline.weight(.semibold))
      }
      ForEach(capabilities) { capability in
        FeatureRow(capability: capability, isAvailable: false)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 4)
  }
}

/// One feature: what it is, and one line on what it does.
private struct FeatureRow: View {
  let capability: PrivateAPICapability
  let isAvailable: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // A checkmark and a lock rather than colour alone — the difference between these two
      // rows has to survive being read by somebody who cannot tell green from grey.
      Image(systemName: isAvailable ? "checkmark.circle.fill" : "lock.circle")
        .foregroundStyle(isAvailable ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(capability.title)
          .font(.body)
          .foregroundStyle(isAvailable ? .primary : .secondary)
        Text(capability.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(capability.title). \(capability.summary) "
        + (isAvailable
          ? "Available on this Mac."
          : "Requires \(PrivateAPICapability.releaseName(capability.minimumMacOS))."))
  }
}
