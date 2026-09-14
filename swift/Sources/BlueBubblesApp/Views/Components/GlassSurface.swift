//  GlassSurface
//  Liquid Glass on macOS 26, a material below it, and a plain fill where neither is affordable.
//
//  Applied to chrome only: the sidebar, toolbars, and stat cards. Content surfaces stay
//  opaque: glass behind a paragraph of text reduces contrast against whatever happens to be
//  on the desktop behind the window, and log lines and message text are the things people
//  actually read.
//
//  The OS version cannot be the only question asked here, and it used to be the only one.
//  A large share of this server's installs are 2012-2017 Intel Macs running macOS 26 through
//  OpenCore Legacy Patcher -- so they take the NEWEST and most GPU-hungry branch, and they are
//  the machines most likely to have no working Metal driver, where every blurred surface falls
//  back to software compositing. There are 35 call sites, several of them per row in scrolling
//  lists, so a list of alerts recomposites N blur layers a frame.
//
//  Two questions are asked instead. `accessibilityReduceTransparency` is the user's own
//  preference and the one macOS already offers for exactly this; it is read from the
//  environment so it applies the moment it changes, with no relaunch. `hasMetalDevice` is the
//  machine's answer, read once, because a GPU does not appear at runtime.
//
//  See `.claude/docs/architecture.md`.

import Metal
import SwiftUI

/// Whether this Mac can composite a blur without the CPU doing it.
///
/// `MTLCreateSystemDefaultDevice()` returning nil is the honest form of the question: it is
/// what a patched Mac with no supported GPU driver reports, and it is not inferable from the
/// OS version, which on those machines says macOS 26.
///
/// Read once and held. A Mac does not grow a GPU while the app is running, and the call is not
/// free enough to make per view body.
enum GraphicsCapability {
  static let hasMetalDevice: Bool = MTLCreateSystemDefaultDevice() != nil
}

/// Which of the three surfaces a call site gets.
enum SurfaceStyle: Equatable {
  /// Liquid Glass. macOS 26 and later, on a machine that can composite it.
  case glass
  /// `.regularMaterial`. Older macOS, still sampling what is behind the window.
  case material
  /// An opaque fill and a hairline. Samples nothing.
  case plain
}

/// Off the view on purpose: a `View`'s statics cannot be reached from a test process, and the
/// case that matters here is precisely the one no one here can observe -- macOS 26 on a
/// machine with no Metal device, which is a patched 2013 Mac and not anything in this office.
enum GlassSurfacePolicy {

  /// The user's preference wins over everything, then the machine's ability, then the OS.
  ///
  /// Ordering matters: asking the OS version first is what the code did, and on the hardware
  /// this server is most often deployed to that answer is "macOS 26", which sent the weakest
  /// machines down the most expensive path.
  static func style(
    reduceTransparency: Bool,
    hasMetalDevice: Bool,
    supportsLiquidGlass: Bool
  ) -> SurfaceStyle {
    if reduceTransparency { return .plain }
    if !hasMetalDevice { return .plain }
    return supportsLiquidGlass ? .glass : .material
  }
}

/// The three surfaces, in the order they are preferred.
private struct GlassSurfaceModifier: ViewModifier {
  /// The user's own "reduce transparency" preference, live from the environment: flipping it
  /// in System Settings restyles every call site without a relaunch.
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var cornerRadius: CGFloat
  var tint: Color?

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
  }

  /// `#available` rather than a compile-time check, so ONE binary runs correctly on every
  /// supported OS; the answer is handed to the policy rather than branched on here.
  private var supportsLiquidGlass: Bool {
    if #available(macOS 26.0, *) { return true }
    return false
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    switch GlassSurfacePolicy.style(
      reduceTransparency: reduceTransparency,
      hasMetalDevice: GraphicsCapability.hasMetalDevice,
      supportsLiquidGlass: supportsLiquidGlass
    ) {
    case .plain:
      // No sampling of what is behind the window at all: an opaque fill and a hairline, which
      // is what the material would have approximated anyway once the CPU finished blurring it.
      content.background(
        shape
          .fill(Color(nsColor: .controlBackgroundColor))
          .overlay(shape.fill(tint ?? .clear))
          .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
      )
    case .glass:
      if #available(macOS 26.0, *) {
        if let tint {
          content.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
        } else {
          content.glassEffect(in: .rect(cornerRadius: cornerRadius))
        }
      }
    case .material:
      content.background(
        shape
          .fill(.regularMaterial)
          // Over the material, not under it: a tint behind `.regularMaterial` is
          // blurred away to nothing.
          .overlay(shape.fill(tint ?? .clear))
      )
    }
  }
}

extension View {
  /// Glass where available and affordable, `.regularMaterial` below macOS 26, and a plain
  /// fill where the machine or the user says no to both.
  ///
  /// The choice itself is `GlassSurfacePolicy.style`, off the view so it can be tested.
  ///
  /// `tint` washes the surface with a colour rather than replacing it; the material still
  /// samples what is behind the window. Keep it faint: this is for saying "this one is
  /// different from its neighbours", not for colouring a card in.
  func glassSurface(cornerRadius: CGFloat = 12, tint: Color? = nil) -> some View {
    modifier(GlassSurfaceModifier(cornerRadius: cornerRadius, tint: tint))
  }
}

/// A card, used for the status tiles on Home.
struct GlassCard<Content: View>: View {
  /// Faint wash over the card's glass, for the rare case where one card in a stack has to
  /// read as different from the others. `nil` (the default, and what nearly every call
  /// site wants) is the plain surface.
  var tint: Color?
  var content: Content

  init(tint: Color? = nil, @ViewBuilder content: () -> Content) {
    self.tint = tint
    self.content = content()
  }

  var body: some View {
    content
      // Matched to `SettingsMetrics.cardPadding` and the settings cards' corner radius,
      // so a card on Home and a card on a settings page are visibly the same object.
      .padding(SettingsMetrics.cardPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .glassSurface(cornerRadius: 16, tint: tint)
  }
}

/// A labelled status dot.
///
/// The colour is never the only signal; every use pairs it with text. Roughly one in twelve
/// men has some form of colour-vision deficiency, and red-versus-green is the pairing they
/// most often cannot separate, which is exactly the distinction a status indicator makes.
struct StatusDot: View {
  enum Level { case ok, warning, bad, unknown }

  var level: Level
  var label: String

  private var color: Color {
    switch level {
    case .ok: .green
    case .warning: .orange
    case .bad: .red
    case .unknown: .secondary
    }
  }

  private var symbol: String {
    switch level {
    case .ok: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .bad: "xmark.circle.fill"
    case .unknown: "questionmark.circle.fill"
    }
  }

  var body: some View {
    Label {
      Text(label)
    } icon: {
      Image(systemName: symbol).foregroundStyle(color)
    }
    .accessibilityLabel("\(label)")
  }
}
