//  QuickTunnelAddressTests
//  Which URL in cloudflared's output is the address this server publishes.
//
//  "The first https:// on a line that mentions trycloudflare.com" matched Cloudflare's own
//  API endpoint. cloudflared names `https://api.trycloudflare.com/tunnel` in its errors, so
//  a failed quick-tunnel request published that as the server's address: it was found in a
//  live install's settings store as `https://api.trycloudflare.com/tunnel":`, complete with
//  the JSON punctuation, having been announced to Firebase and handed to clients.
//
//  See `Sources/BBProxy/Tunnels.swift`.

import Foundation
import Testing

@testable import BBProxy

@Suite("Quick tunnel address")
struct QuickTunnelAddressTests {

  /// The line cloudflared actually prints, inside its ASCII box.
  @Test("The assigned address is taken from the announcement box")
  func readsTheAnnouncement() {
    let line =
      "|  https://harvest-monkey-ruled-panels.trycloudflare.com                          |"
    #expect(
      Tunnels.quickTunnelAddress(in: line)
        == "https://harvest-monkey-ruled-panels.trycloudflare.com"
    )
  }

  /// The exact shape that reached a real settings store.
  @Test("Cloudflare's API endpoint is not an address")
  func rejectsTheAPIEndpoint() {
    let line =
      #"{"level":"error","error":"failed to request quick Tunnel: "#
      + #"Post \"https://api.trycloudflare.com/tunnel\": context deadline exceeded"}"#
    #expect(Tunnels.quickTunnelAddress(in: line) == nil)
  }

  /// A path is the tell. An assigned quick tunnel is a bare origin; anything with a path is
  /// an endpoint being talked ABOUT.
  @Test("A trycloudflare URL with a path is not an address")
  func rejectsAPath() {
    #expect(Tunnels.quickTunnelAddress(in: "https://foo.trycloudflare.com/some/path") == nil)
  }

  /// `trycloudflare.com` appearing as a bare host, or inside another domain, is not a
  /// subdomain of it: `hasSuffix("trycloudflare.com")` without the dot would take both.
  @Test(
    "Only a subdomain of trycloudflare.com counts",
    arguments: [
      "https://trycloudflare.com",
      "https://nottrycloudflare.com",
      "https://trycloudflare.com.evil.example",
    ]
  )
  func rejectsNearMisses(url: String) {
    #expect(Tunnels.quickTunnelAddress(in: "|  \(url)  |") == nil)
  }

  @Test("A line with no URL yields nothing")
  func ignoresOtherOutput() {
    #expect(
      Tunnels.quickTunnelAddress(in: "Requesting new quick Tunnel on trycloudflare.com...")
        == nil
    )
  }

  /// A trailing quote from a JSON body must not survive into the published address.
  @Test("Surrounding punctuation is stripped")
  func stripsPunctuation() {
    #expect(
      Tunnels.quickTunnelAddress(in: #""https://abc-def.trycloudflare.com","#)
        == "https://abc-def.trycloudflare.com"
    )
  }
}
