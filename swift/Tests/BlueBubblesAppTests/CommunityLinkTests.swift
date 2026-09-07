//  CommunityLinkTests
//  The toolbar links are well-formed, so a malformed one fails here rather than at launch.
//
//  Scope, because the obvious test is the wrong one. Asserting each `url.absoluteString`
//  against the literal in `CommunityLinks.swift`, or the array order against the order
//  written there, restates the declaration: the only way to make either fail is to change
//  the links on purpose, and then the fix is to edit the test. Both were removed. Where the
//  addresses came from — a transcription of the Electron UI's `Navigation.tsx` — is recorded
//  next to the declaration itself, which is where a reader with a doubt about `yC4wr38` will
//  actually be looking.
//
//  What is left can fail by accident. `CommunityLink.all` force-unwraps `URL(string:)`, so a
//  typo that stops parsing traps the app on launch with no message; catching it here names
//  the link instead. `http` in place of `https` is the same shape of slip.

import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Community links")
struct CommunityLinkTests {

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
