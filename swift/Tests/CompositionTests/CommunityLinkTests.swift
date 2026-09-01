//  CommunityLinkTests
//  The toolbar links point where they are supposed to.
//
//  A wrong URL here is the worst kind of small bug: the button renders, the tooltip is right,
//  the click opens a browser, and the user lands on a 404. Nothing in the app can tell.
//
//  `discord.gg/yC4wr38` is the case that motivates the test — an opaque invite code nobody can
//  proofread. These are transcribed from the Electron UI
//  (`packages/ui/src/app/containers/navigation/Navigation.tsx`), and this pins the
//  transcription.

import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Community links")
struct CommunityLinkTests {

  @Test("Every link points at the address the Electron UI used")
  func urlsMatchTheReference() {
    let byID = Dictionary(
      uniqueKeysWithValues: CommunityLink.all.map { ($0.id, $0.url.absoluteString) })

    #expect(byID["docs"] == "https://docs.bluebubbles.app")
    #expect(byID["discord"] == "https://discord.gg/yC4wr38")
    #expect(byID["donate"] == "https://bluebubbles.app/donate")
  }

  /// Order is a design decision, not an accident: documentation leads because it is the one
  /// with an answer in it, and the support link is last because one that leads the row reads
  /// as a nag.
  @Test("Documentation leads and donate trails")
  func orderIsDeliberate() {
    #expect(CommunityLink.all.map(\.id) == ["docs", "discord", "donate"])
  }

  /// Every link is HTTPS and reachable as a real URL. A `URL(string:)!` on a malformed
  /// string would trap at launch rather than here.
  @Test("Links are well-formed and secure")
  func urlsAreWellFormed() {
    for link in CommunityLink.all {
      #expect(link.url.scheme == "https", "\(link.id) is not https")
      #expect(link.url.host?.isEmpty == false, "\(link.id) has no host")
      #expect(!link.title.isEmpty)
      #expect(!link.symbol.isEmpty)
    }
  }
}
