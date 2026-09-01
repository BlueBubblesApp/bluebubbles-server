//  OAuthFlowTests
//  The browser hand-off.
//
//  The redirect URI is registered with Google and cannot be changed from here, so the tests
//  that pin it are not pedantry — a "harmless" refactor of the port or path breaks setup for
//  every user until someone updates the OAuth client in a console this repository has no
//  access to.

import Foundation
import Testing

@testable import BBPushKit

@Suite("OAuth configuration")
struct OAuthConfigurationTests {

  /// Google rejects any redirect that does not match the registration exactly.
  @Test("The redirect URI matches what is registered with Google")
  func redirectURIIsFixed() {
    let configuration = OAuthConfiguration()
    #expect(configuration.port == 8641)
    #expect(configuration.redirectURI == "http://localhost:8641/oauth/callback")
  }

  @Test("The authorization URL carries the client, redirect and scopes")
  func authorizationURLShape() throws {
    let configuration = OAuthConfiguration()
    let url = configuration.authorizationURL(for: .firebase)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )

    #expect(components.host == "accounts.google.com")
    #expect(items["client_id"] == configuration.clientId)
    #expect(items["redirect_uri"] == "http://localhost:8641/oauth/callback")
    // The implicit flow, inherited from the client registration.
    #expect(items["response_type"] == "token")
    #expect(items["state"] == "firebase")

    let scopes = items["scope"]?.split(separator: " ").map(String.init) ?? []
    #expect(scopes.contains("https://www.googleapis.com/auth/firebase"))
    #expect(scopes.contains("https://www.googleapis.com/auth/iam"))
  }

  /// Provisioning is the ONLY thing this server asks Google for.
  ///
  /// The current server also runs a `contacts.readonly` flow, to work around
  /// `node-mac-contacts` not seeing CardDAV accounts. That does not exist here — the address
  /// book hands us Google contacts already — and this asserts it stays gone: a contacts
  /// scope reappearing means someone has reintroduced a second, competing source of
  /// contacts behind a second consent screen.
  @Test("Only Firebase scopes are ever requested")
  func onlyProvisioningScopesAreRequested() {
    #expect(!OAuthPurpose.firebase.scopes.contains { $0.contains("contacts") })
    #expect(OAuthPurpose.firebase.scopes.allSatisfy { $0.hasPrefix("https://") })
    #expect(OAuthPurpose.firebase.scopes.count > 1)
  }
}

@Suite("OAuth callback parsing")
struct OAuthCallbackTests {

  /// With the implicit flow the token arrives in the URL fragment, which the browser never
  /// sends to the server — the landing page reads it and posts it back.
  @Test("An access token is extracted from the fragment")
  func extractsToken() {
    let fragment = "#access_token=ya29.abc123&token_type=Bearer&expires_in=3599"
    #expect(CallbackHandlerAccess.accessToken(inFragment: fragment) == "ya29.abc123")
  }

  @Test("A fragment without a leading hash still parses")
  func toleratesMissingHash() {
    #expect(
      CallbackHandlerAccess.accessToken(
        inFragment: "access_token=abc&scope=x"
      ) == "abc")
  }

  /// A denied consent screen returns an error rather than a token, and must not be mistaken
  /// for success.
  @Test("An error response yields no token")
  func errorFragmentYieldsNothing() {
    #expect(
      CallbackHandlerAccess.accessToken(
        inFragment: "#error=access_denied&state=firebase"
      ) == nil)
    #expect(CallbackHandlerAccess.accessToken(inFragment: "") == nil)
  }

  @Test("A percent-encoded token is decoded")
  func decodesPercentEncoding() {
    #expect(
      CallbackHandlerAccess.accessToken(
        inFragment: "#access_token=abc%2Fdef"
      ) == "abc/def")
  }

  /// The token must not be left in the address bar, where it lands in browser history.
  @Test("The landing page clears the fragment from history")
  func landingPageClearsHistory() {
    let page = CallbackHandlerAccess.landingPage
    #expect(page.contains("history.replaceState"))
    #expect(page.contains("/oauth/token"))
  }
}
