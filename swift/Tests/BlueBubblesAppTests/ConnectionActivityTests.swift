//  ConnectionActivityTests
//  What the corner-of-every-page indicator says, and when it says nothing.

import BBBuiltIns
import BBServiceKit
import Testing

@testable import BlueBubblesApp

@Suite("Connection activity")
struct ConnectionActivityTests {

  @Test("Reconnecting names the method, and the tunnel's own reason when it gave one")
  func reconnectingSummaries() {
    let bare = ConnectionActivity.reconnecting(method: "Tailscale", detail: "")
    #expect(bare.summary == "Reconnecting Tailscale…")
    #expect(bare.isInProgress)

    let explained = ConnectionActivity.reconnecting(
      method: "Tailscale", detail: "waiting for you to sign in to Tailscale")
    #expect(explained.summary == "Reconnecting Tailscale: waiting for you to sign in to Tailscale")
  }

  @Test("Connected and failed are not in progress, and say which they are")
  func terminalStates() {
    let connected = ConnectionActivity.connected(method: "ngrok")
    #expect(!connected.isInProgress)
    #expect(connected.summary == "ngrok is connected")

    let failed = ConnectionActivity.failed(method: "ngrok", reason: "the tunnel exited")
    #expect(!failed.isInProgress)
    #expect(failed.summary == "ngrok failed: the tunnel exited")
    #expect(failed.method == "ngrok")
  }

  /// The state that fixed a spinner which never stopped.
  ///
  /// Switching the HTTP API off strands every tunnel on it. That is not a reconnect; no
  /// amount of waiting resolves it, so it must not report as work in flight, or the
  /// background list holds a row for as long as the HTTP API stays off.
  @Test("A method stranded by a switched-off dependency is not in progress")
  func unavailableIsNotProgress() {
    let stranded = ConnectionActivity.unavailable(
      method: "Tailscale", reason: "HTTP API is switched off")
    #expect(!stranded.isInProgress)
    #expect(stranded.method == "Tailscale")
    #expect(stranded.summary == "Tailscale is not running: HTTP API is switched off")
    // It still says something, which `BackgroundActivity.describing` requires of anything
    // that does reach a row.
    #expect(stranded.detailOrDefault == "HTTP API is switched off")
  }

  /// REGRESSION. The selected method's own switch, turned off.
  ///
  /// `resolve` used to reach the health switch for this, where `inactive(reason:)` fell to a
  /// `routine` list of three strings that does not contain the registry's "switched off", so
  /// it became `.reconnecting` — in progress, forever, because nothing was running to make
  /// progress. The symptom was a permanent "Tailscale — switched off" row in the background
  /// task list. The dependency case beside it had been fixed structurally; this one had not.
  @Test("A method whose own switch is off is not in progress")
  func switchedOffIsNotProgress() {
    let off = ConnectionActivity.resolve(
      method: "Tailscale",
      // The health the registry actually publishes for it, reason and all.
      health: .inactive(reason: "switched off"),
      isSwitchedOff: true,
      strandedBy: nil
    )
    #expect(!off.isInProgress, "a switched-off method spun in the background list forever")
    #expect(off == .unavailable(method: "Tailscale", reason: "it is switched off"))
    #expect(off.summary == "Tailscale is not running: it is switched off")
  }

  /// The switch is asked about separately from the health, so it wins whatever the registry
  /// happens to say: a service switched off before it ever started reports `.stopped`.
  @Test("The switch decides, not the wording the registry used")
  func theSwitchOutranksTheReason() {
    for health: ServiceHealth in [
      .stopped, .starting, .inactive(reason: "switched off"), .inactive(reason: "not started"),
    ] {
      let off = ConnectionActivity.resolve(
        method: "Tailscale", health: health, isSwitchedOff: true, strandedBy: nil)
      #expect(!off.isInProgress, "\(health) with the switch off still reported work in flight")
    }
  }

  /// A dependency that is off still outranks the service's own switch, and still names the
  /// dependency: "it is switched off" on a tunnel whose HTTP API is the thing that is off
  /// would send someone to the wrong switch.
  @Test("A stranded method names the dependency, not itself")
  func strandingWins() {
    let stranded = ConnectionActivity.resolve(
      method: "Tailscale", health: .stopped, isSwitchedOff: true, strandedBy: "HTTP API")
    #expect(stranded == .unavailable(method: "Tailscale", reason: "HTTP API is switched off"))
  }

  /// And the states that ARE in flight still are: the fix must not silence a real restart.
  @Test("A running method is connected, and a restarting one is still in progress")
  func liveStatesSurvive() {
    #expect(
      ConnectionActivity.resolve(
        method: "Tailscale", health: .running, isSwitchedOff: false, strandedBy: nil)
        == .connected(method: "Tailscale"))

    let restarting = ConnectionActivity.resolve(
      method: "Tailscale", health: .starting, isSwitchedOff: false, strandedBy: nil)
    #expect(restarting.isInProgress)

    // The registry's bookkeeping mid-restart, which is in flight and says nothing extra.
    let routine = ConnectionActivity.resolve(
      method: "Tailscale", health: .inactive(reason: "not connected"), isSwitchedOff: false,
      strandedBy: nil)
    #expect(routine == .reconnecting(method: "Tailscale", detail: ""))

    // A tunnel explaining itself, which is in flight and does.
    let explained = ConnectionActivity.resolve(
      method: "Tailscale",
      health: .inactive(reason: "waiting for you to sign in to Tailscale"),
      isSwitchedOff: false, strandedBy: nil)
    #expect(explained.isInProgress)
    #expect(explained.detailOrDefault == "waiting for you to sign in to Tailscale")

    let failed = ConnectionActivity.resolve(
      method: "Tailscale", health: .failed(reason: "the tunnel exited"), isSwitchedOff: false,
      strandedBy: nil)
    #expect(!failed.isInProgress)
  }

  /// `connectionActivity` finds the stranding structurally, by walking the selected
  /// method's declared dependencies, rather than by matching the registry's wording. That
  /// only works while the dependency is actually declared, so this pins it.
  @Test("A tunnel declares the HTTP API as a dependency, which is what makes it strandable")
  func tunnelsDependOnTheListener() {
    for manifest in [
      BuiltInManifests.tailscale, BuiltInManifests.ngrok, BuiltInManifests.cloudflare,
      BuiltInManifests.zrok, BuiltInManifests.lan,
    ] {
      #expect(
        manifest.dependencies.contains(BuiltInManifests.ID.http),
        "\(manifest.name) does not declare the HTTP API, so nothing would notice it stranded"
      )
    }
  }
}
