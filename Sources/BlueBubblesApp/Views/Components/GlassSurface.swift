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
  func glassSurface(
    cornerRadius: CGFloat = SettingsMetrics.tileCornerRadius, tint: Color? = nil
  ) -> some View {
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
      // The settings cards' padding and corner radius, so a card on Home and a card on a
      // settings page are visibly the same object.
      .padding(SettingsMetrics.cardPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .glassSurface(cornerRadius: SettingsMetrics.cardCornerRadius, tint: tint)
  }
}

/// A card for CONTENT, on an opaque surface.
///
/// The same shape, padding and hairline as `GlassCard`, and deliberately none of the glass.
/// This file's first paragraph is the rule and this is the first call site that needs it
/// stated as a type: chrome samples what is behind the window, content does not, "because
/// glass behind a paragraph of text reduces contrast against whatever happens to be on the
/// desktop behind the window".
///
/// SIZE is what made the rule visible. A stat card is small enough that what it samples reads
/// as texture; the Contacts card fills the page, so it samples a page-sized piece of desktop —
/// and with the window at the top of the screen that was blue, so the page was blue. Nothing
/// in the app is that colour, which is what made it hard to find.
///
/// It is the SAME surface every Mac without a Metal device already gets from `glassSurface`,
/// so this is not a second look: it is the existing fallback, chosen deliberately rather than
/// by hardware.
struct ContentCard<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous)
  }

  var body: some View {
    content
      .padding(SettingsMetrics.cardPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        shape
          .fill(Color(nsColor: .controlBackgroundColor))
          .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
      )
  }
}

/// A labelled status dot.
///
/// The colour is never the only signal; every use pairs it with text. Roughly one in twelve
/// men has some form of colour-vision deficiency, and red-versus-green is the pairing they
/// most often cannot separate, which is exactly the distinction a status indicator makes.
struct StatusDot: View {
  var tone: StatusTone
  var label: String

  var body: some View {
    Label {
      Text(label)
    } icon: {
      Image(systemName: tone.symbol).foregroundStyle(tone.tint)
    }
    .accessibilityLabel("\(label)")
  }
}

// MARK: - Grouping

/// The glass surfaces inside it are ONE surface.
///
/// `glassEffect` on its own composites each card as its own layer, so a page of twelve cards is
/// twelve independent blurs that do not blend where they meet and do not morph when one
/// appears. macOS 26's `GlassEffectContainer` is how adjacent glass is meant to be drawn:
/// sampled once and blended across the gaps. Not cheaper, as measured: a changed pixel
/// inside any card costs about 200 MB of graphics memory per repaint with the container and
/// exactly the same without it, so what the container buys is the blending, and what keeps
/// a page cheap is how often anything inside the glass changes (see the Home rules in this
/// module's `CLAUDE.md`). Every page that stacks glass cards (`SettingsPage`, the alerts
/// drawer) goes through this, so the pages agree and a new one cannot forget. Below macOS 26
/// it is the content, unchanged.
struct GlassGroup<Content: View>: View {
  /// How close two surfaces have to be before they MERGE into one shape.
  ///
  /// Below the tightest gap any grid on any page uses (the Home tiles sit 12 points apart),
  /// so cards that are laid out as separate cards stay separate. Set to the section spacing
  /// this fused every tile on Home into its neighbours at the corners, which is the effect
  /// for shapes that move together (a toolbar splitting into buttons), not for a grid.
  /// What the container still buys at this distance is the blending where cards meet; it
  /// does not make a repaint cheaper, see the type's header.
  var spacing: CGFloat = SettingsMetrics.glassMergeDistance
  private let content: Content

  init(
    spacing: CGFloat = SettingsMetrics.glassMergeDistance, @ViewBuilder content: () -> Content
  ) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) { content }
    } else {
      content
    }
  }
}

// MARK: - Buttons

/// A prominent button that sits on the window itself rather than in a card.
///
/// Liquid Glass buttons are for controls floating over content: the Start button under
/// "Server not running", the Start/Stop in the sidebar strip. Inside a glass card the ordinary
/// bordered style is right and this is wrong: glass on glass is the one thing the design
/// language rules out, so the call sites are the handful of buttons with nothing glass behind
/// them. The same policy as `glassSurface` decides, so Reduce Transparency and a Mac with no
/// GPU get the bordered style.
private struct ProminentGlassButtonModifier: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *),
      GlassSurfacePolicy.style(
        reduceTransparency: reduceTransparency,
        hasMetalDevice: GraphicsCapability.hasMetalDevice,
        supportsLiquidGlass: true
      ) == .glass
    {
      content.buttonStyle(.glassProminent)
    } else {
      content.buttonStyle(.borderedProminent)
    }
  }
}

extension View {
  /// See `ProminentGlassButtonModifier`. `when` is for a button drawn in more than one
  /// placement, of which only some float: false leaves the button's style alone.
  @ViewBuilder
  func prominentGlassButton(when floats: Bool = true) -> some View {
    if floats {
      modifier(ProminentGlassButtonModifier())
    } else {
      self
    }
  }
}
