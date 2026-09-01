//  FloatingBar
//  The floating glass selector used at the bottom of a page.
//
//  One component, two users so far: the settings tabs and the log-level filter. Standardising
//  it is the point — a second hand-rolled glass bar would drift in padding, in animation
//  timing, and in whether it minimises, and the user would learn the behaviour twice.
//
//  Why floating rather than a header row: glass only does anything when there is content
//  moving behind it. A bar pinned in a static header refracts a fixed background and reads as
//  a flat translucent strip, which is the version of Liquid Glass everyone complains about.
//
//  ## Minimising
//
//  It collapses to the selected item alone after a few idle seconds and comes back on hover
//  or click. A bar over content is a bar covering content, and the trade is only worth making
//  if it gets out of the way once you have stopped using it.
//
//  Two rules keep that from being annoying:
//    - Hovering CANCELS the countdown rather than merely restarting it, so a pointer resting
//      on the bar never has it collapse underneath.
//    - Reduce Motion disables both the animation and the auto-collapse. Something that moves
//      on its own timer is exactly what that setting is asking us not to do.

import SwiftUI

struct FloatingBarItem<Value: Hashable>: Identifiable {
  let value: Value
  let title: String
  let symbol: String
  /// Drawn on the icon when greater than zero.
  var badge: Int = 0

  var id: Value { value }

  init(value: Value, title: String, symbol: String, badge: Int = 0) {
    self.value = value
    self.title = title
    self.symbol = symbol
    self.badge = badge
  }
}

struct FloatingBar<Value: Hashable>: View {

  @Binding var selection: Value
  let items: [FloatingBarItem<Value>]
  /// Collapse to the selected item after this long without interaction.
  var minimizeAfter: Duration? = .seconds(5)

  /// What a page should leave clear at its bottom edge.
  static var reservedHeight: CGFloat { 96 }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var isMinimized = false
  @State private var isHovering = false
  /// Bumped by every interaction; the collapse countdown restarts on change.
  @State private var activity = 0

  private var animation: Animation? {
    reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82)
  }

  var body: some View {
    Group {
      if isMinimized {
        minimized
      } else {
        expanded
      }
    }
    .padding(6)
    .glassSurface(cornerRadius: 30)
    // Glass alone does not separate the bar from a card of similar tone scrolling under it.
    .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
    .padding(.bottom, 18)
    .animation(animation, value: isMinimized)
    .onHover { hovering in
      isHovering = hovering
      // Coming back on hover, rather than only on click: the bar is a target you were
      // already reaching for, and making you click once to reveal and once to choose
      // would be a worse trade than the space it was hiding.
      if hovering, isMinimized { expand() }
      // Leaving restarts the countdown; `.task(id:)` only re-runs when this changes.
      if !hovering { activity += 1 }
    }
    .task(id: activity) { await scheduleMinimize() }
  }

  // MARK: - States

  private var expanded: some View {
    HStack(spacing: 2) {
      ForEach(items) { item in
        Button {
          selection = item.value
          activity += 1
        } label: {
          label(for: item, compact: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selection == item.value ? [.isSelected] : [])
      }
    }
    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
  }

  private var minimized: some View {
    Button {
      expand()
    } label: {
      HStack(spacing: 7) {
        if let current {
          Image(systemName: current.symbol).font(.system(size: 15))
          Text(current.title).font(.callout.weight(.medium))
        }
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 14)
      .frame(height: 34)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.tint)
    // Says what it does. A collapsed control with no affordance is a control people stop
    // believing is a control.
    .help("Show all options")
    .accessibilityLabel("\(current?.title ?? "Selection"). Show all options.")
    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
  }

  private var current: FloatingBarItem<Value>? {
    items.first { $0.value == selection }
  }

  private func label(for item: FloatingBarItem<Value>, compact: Bool) -> some View {
    let isSelected = selection == item.value
    return VStack(spacing: 3) {
      ZStack(alignment: .topTrailing) {
        Image(systemName: item.symbol)
          .font(.system(size: 16))
          .frame(height: 18)
        if item.badge > 0 {
          Text("\(item.badge)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(.red, in: Capsule())
            .offset(x: 12, y: -6)
        }
      }
      Text(item.title).font(.caption)
    }
    .frame(width: 76, height: 48)
    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .fill(.tint.opacity(0.16))
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
  }

  // MARK: - Minimising

  private func expand() {
    isMinimized = false
    activity += 1
  }

  private func scheduleMinimize() async {
    guard let minimizeAfter, !reduceMotion else { return }
    try? await Task.sleep(for: minimizeAfter)
    // Checked AFTER the sleep as well as before: the pointer may have arrived while we
    // were waiting, and collapsing under a resting cursor is the thing that would make
    // this feature something people want turned off.
    guard !Task.isCancelled, !isHovering else { return }
    isMinimized = true
  }
}
