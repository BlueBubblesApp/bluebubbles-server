//  SearchIndexSettingTests
//  The search index switch, and the one property of it that is security rather than taste.
//
//  `search_index_enabled` is the consent for building a word list derived from message text
//  and keeping it in a file that, unlike `chat.db`, no TCC prompt stands in front of. The
//  default being `false` is not caution and not a placeholder: it is the whole reason the
//  feature is defensible, because it means nobody who does not choose this acquires a new
//  exposure — every existing install included, since an upgrade reads a key that is not there
//  and gets the default.
//
//  A default flipped to `true`, by intent or by an editing slip, would be invisible in review
//  and would silently index every user's history on their next update. So it is pinned here.
//
//  See `docs/SEARCH.md`.

import Testing

@testable import BBSettings

@Suite("Search index setting")
struct SearchIndexSettingTests {

  @Test("It is off unless somebody turns it on")
  func defaultsOff() {
    #expect(
      Settings.searchIndexEnabled.defaultValue == false,
      """
      search_index_enabled must default to false. It consents to building an index derived \
      from message text, and the default is what decides whether an upgrade does that \
      without asking.
      """)
  }

  @Test("It is reachable: declared, and on the screen")
  func isDeclaredAndRenderable() {
    // Either omission is silent. A key missing from `allKeys` cannot be written through the
    // config file or the API; one missing from `renderable` never appears in the app, so
    // the onboarding step would be the only place it could ever be changed.
    #expect(Settings.allKeys.contains(Settings.searchIndexEnabled.key))
    #expect(Settings.renderable.contains { $0.key == Settings.searchIndexEnabled.key })
  }

  @Test("It applies live, because turning it on has to do something")
  func appliesLive() {
    // `.composition` would mean the switch moves and nothing happens until a restart, which
    // is the failure `requires:` and `application:` both exist to prevent. The indexer
    // watches this key and starts on the change.
    #expect(Settings.searchIndexEnabled.application == .live)
  }

  @Test("It stands alone: no parent switch to grey it out")
  func hasNoRequirement() {
    // Worth pinning because it is a plausible future mistake: search is not Private API
    // surface and must not be made to depend on `enable_private_api`. The index is the
    // route that works precisely when the Private API is off.
    #expect(Settings.searchIndexEnabled.presentation?.requires == nil)
  }

  @Test("It is not a secret, so it is readable by a service")
  func isNotSecret() {
    // A service can never declare a read of a secret — `checkRead` refuses before it looks
    // at entitlements — so marking this secret would make the indexer unable to read its own
    // switch.
    #expect(!Settings.secretKeys.contains(Settings.searchIndexEnabled.key))
  }
}
