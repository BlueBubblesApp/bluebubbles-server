//  ConnectionMethodChoicesTests
//  The recommendation is one method, shown first and named as such.

import BBBuiltIns
import Testing

@testable import BlueBubblesApp

@Suite("Connection method choices")
struct ConnectionMethodChoicesTests {

  @Test("Tailscale is recommended, listed first, and labelled as the recommendation")
  func recommendedComesFirst() {
    let choices = ConnectionMethodChoices.available()
    #expect(choices.first?.value == BuiltInManifests.ID.proxyTailscale.rawValue)
    #expect(choices.first?.label == "Tailscale (Recommended)")
    // Exactly one, or "recommended" means nothing.
    #expect(choices.filter { $0.label.contains("(Recommended)") }.count == 1)
    #expect(ConnectionMethodChoices.isRecommended(BuiltInManifests.tailscale))
    #expect(!ConnectionMethodChoices.isRecommended(BuiltInManifests.cloudflare))
    // Everything else is shown under its own name, unmarked.
    let cloudflare = BuiltInManifests.cloudflare
    #expect(ConnectionMethodChoices.label(for: cloudflare) == cloudflare.name)
  }
}
