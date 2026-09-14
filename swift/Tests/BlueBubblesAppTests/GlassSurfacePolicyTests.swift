//  GlassSurfacePolicyTests
//  Which surface a machine gets, and why the OS version cannot be the only question.
//
//  `glassSurface` branched on `#available(macOS 26.0, *)` and nothing else, across 35 call
//  sites, several of them per row in scrolling lists. The hardware this server is most often
//  deployed to makes that exactly backwards: a 2012-2017 Intel Mac patched with OpenCore
//  Legacy Patcher REPORTS macOS 26, so it took the newest and most GPU-hungry branch, and it
//  is the machine most likely to have no working Metal driver -- where every blurred surface
//  falls back to software compositing.
//
//  The whole app module contained zero references to the reduce-transparency preference, which
//  is the control macOS already offers for this and the one a person on such a Mac is most
//  likely to have turned on.

import Testing

@testable import BlueBubblesApp

@Suite("Glass surface policy")
struct GlassSurfacePolicyTests {

  /// The case this exists for, and the one nobody here can observe: macOS 26 on a machine
  /// with no Metal device.
  @Test("A patched Mac reporting macOS 26 with no GPU gets the plain surface")
  func patchedMacWithoutMetalGetsPlain() {
    #expect(
      GlassSurfacePolicy.style(
        reduceTransparency: false, hasMetalDevice: false, supportsLiquidGlass: true) == .plain)
  }

  @Test("The reduce-transparency preference wins, whatever the machine can do")
  func preferenceWins() {
    #expect(
      GlassSurfacePolicy.style(
        reduceTransparency: true, hasMetalDevice: true, supportsLiquidGlass: true) == .plain)
    #expect(
      GlassSurfacePolicy.style(
        reduceTransparency: true, hasMetalDevice: true, supportsLiquidGlass: false) == .plain)
  }

  /// Non-vacuity: a policy that answered `.plain` to everything would pass both tests above.
  @Test("A capable Mac still gets glass, and an older one still gets the material")
  func capableMachinesAreUnchanged() {
    #expect(
      GlassSurfacePolicy.style(
        reduceTransparency: false, hasMetalDevice: true, supportsLiquidGlass: true) == .glass)
    #expect(
      GlassSurfacePolicy.style(
        reduceTransparency: false, hasMetalDevice: true, supportsLiquidGlass: false) == .material)
  }

  /// No Metal means no blur of any kind: the material samples what is behind the window too,
  /// so falling back to it on a GPU-less Mac would keep the cost this is removing.
  @Test("No Metal device never yields a surface that samples the desktop")
  func noMetalNeverSamples() {
    for liquidGlass in [true, false] {
      let style = GlassSurfacePolicy.style(
        reduceTransparency: false, hasMetalDevice: false, supportsLiquidGlass: liquidGlass)
      #expect(style == .plain, "supportsLiquidGlass: \(liquidGlass) gave \(style)")
    }
  }

  /// This Mac has a GPU, which is the control for the test above: if this ever fails, the
  /// capability check is answering the wrong question rather than the hardware having changed.
  @Test("This machine reports a Metal device")
  func thisMachineHasMetal() {
    #expect(GraphicsCapability.hasMetalDevice)
  }
}
