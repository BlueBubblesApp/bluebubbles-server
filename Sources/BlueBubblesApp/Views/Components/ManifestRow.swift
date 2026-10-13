//  ManifestRow
//  A row that names an integration: its glyph, its name and tags, a sentence on what it is,
//  what it is doing, and whatever the row leads to.
//
//  Three pages drew this and no two agreed: the Integrations list had no glyph and a dot,
//  the Notifications page had a glyph tinted by whether the route was on, and the Firebase
//  page's registered-devices row had a glyph, a caption-sized sentence and a chevron. The
//  name, the sentence and the status line are the same three facts on all of them, so they
//  are drawn once here and the parts that genuinely differ are slots: the TAGS beside the
//  name (`Tag`, a selected dot) and the TRAILING edge (a button, a count).
//
//  The glyph is `manifest.symbol`, never a switch over built-in ids, so an integration loaded
//  from somewhere else draws its own. The devices row is not a manifest, and takes the same
//  shape through the initialiser that names its parts, because it sits on the same kind of
//  page doing the same job: saying where a press leads.
//
//  The row does not decide what pressing it does. A `NavigationLink` around it, or a button
//  on its trailing edge, is the caller's; a row that also owned its navigation would need a
//  case for every destination type in the app.

import BBServiceKit
import SwiftUI

struct ManifestRow<Tags: View, Trailing: View>: View {

  let symbol: String
  let title: String
  let summary: String
  /// Whether the thing is switched on. Tints the glyph; the words still say it, through a
  /// tag or the status line, because a colour is never the only signal.
  let isActive: Bool
  /// What it is doing, when that is not simply running. `ServiceStatusSummary` decides.
  let status: ServiceStatusSummary.Line?
  /// For a row that navigates: a chevron after the trailing slot, which is how a list row
  /// on macOS says that pressing it goes somewhere.
  let showsChevron: Bool
  private let tags: Tags
  private let trailing: Trailing

  init(
    symbol: String,
    title: String,
    summary: String,
    isActive: Bool = true,
    status: ServiceStatusSummary.Line? = nil,
    showsChevron: Bool = false,
    @ViewBuilder tags: () -> Tags,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.symbol = symbol
    self.title = title
    self.summary = summary
    self.isActive = isActive
    self.status = status
    self.showsChevron = showsChevron
    self.tags = tags()
    self.trailing = trailing()
  }

  /// A row with nothing beside its name: the devices row on the Firebase page.
  init(
    symbol: String,
    title: String,
    summary: String,
    isActive: Bool = true,
    status: ServiceStatusSummary.Line? = nil,
    showsChevron: Bool = false,
    @ViewBuilder trailing: () -> Trailing
  ) where Tags == EmptyView {
    self.init(
      symbol: symbol, title: title, summary: summary, isActive: isActive, status: status,
      showsChevron: showsChevron, tags: { EmptyView() }, trailing: trailing)
  }

  /// An integration's row, in its manifest's own words.
  init(
    manifest: ServiceManifest,
    isActive: Bool,
    status: ServiceStatusSummary.Line? = nil,
    showsChevron: Bool = false,
    @ViewBuilder tags: () -> Tags,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.init(
      symbol: manifest.symbol, title: manifest.name, summary: manifest.summary,
      isActive: isActive, status: status, showsChevron: showsChevron,
      tags: tags, trailing: trailing)
  }

  /// An integration's row with nothing on its trailing edge but, perhaps, the chevron.
  init(
    manifest: ServiceManifest,
    isActive: Bool,
    status: ServiceStatusSummary.Line? = nil,
    showsChevron: Bool = false,
    @ViewBuilder tags: () -> Tags
  ) where Trailing == EmptyView {
    self.init(
      manifest: manifest, isActive: isActive, status: status, showsChevron: showsChevron,
      tags: tags, trailing: { EmptyView() })
  }

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      Image(systemName: symbol)
        .font(.system(size: 16))
        .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .frame(width: SettingsMetrics.iconColumnWidth)
        // The name beside it says what the glyph says.
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(title).font(.body.weight(.medium))
          tags
        }
        Text(summary)
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let status {
          ServiceStatusLine(status, placement: .row)
        }
      }

      Spacer(minLength: 12)
      trailing
      if showsChevron {
        Image(systemName: "chevron.right")
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
    }
    .padding(.vertical, SettingsMetrics.rowSpacing / 2)
    // The whole row is the hit target, padding included, not just the text in it.
    .contentShape(Rectangle())
  }
}
