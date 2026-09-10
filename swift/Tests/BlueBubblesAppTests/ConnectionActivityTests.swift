//  ConnectionActivityTests
//  What the corner-of-every-page indicator says, and when it says nothing.

import BBBuiltIns
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
