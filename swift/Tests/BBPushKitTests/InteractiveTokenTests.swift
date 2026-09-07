//  InteractiveTokenTests
//  The token source the guided Firebase setup runs on.
//
//  Setup authenticates as the USER through the browser, not as a service account — creating a
//  project is something only a human account may do, and there is no service account for a
//  project that does not exist yet. `StaticTokenProvider` is that seam, and its expiry
//  behaviour is deliberately different from the mintable one.
//
//  See `docs/EVENTS.md`.

import Foundation
import Testing

@testable import BBPushKit

@Suite("Interactive OAuth token")
struct InteractiveTokenTests {

  @Test("An interactive token is usable until it actually expires")
  func staticTokenUsable() async throws {
    // No early-refresh leeway, unlike the service-account provider: there is nothing to
    // refresh to, so refusing a token with four minutes left would abandon a provisioning
    // run that would have finished.
    let provider = StaticTokenProvider(
      AccessToken(value: "abc", expiresAt: Date().addingTimeInterval(120))
    )
    #expect(try await provider.token().value == "abc")
  }

  @Test("An expired interactive token says so instead of being sent to Google")
  func staticTokenExpires() async {
    // Sending it would produce a 401 several steps into a provisioning run, which is far
    // harder to explain than "your sign-in expired, sign in again".
    let provider = StaticTokenProvider(
      AccessToken(value: "abc", expiresAt: Date().addingTimeInterval(-1))
    )
    await #expect(throws: GoogleAuthError.interactiveTokenExpired) {
      _ = try await provider.token()
    }
  }
}
