//  UpdateFeedTests
//  The appcast address is declared twice, and the two declarations agree.
//
//  `UpdateFeed.defaultURL` lives in BBSettings so that a module reading a setting does not
//  pull the update machinery in behind it; `UpdateChecker.defaultFeedURL` is the address the
//  checker fetches. Two spellings of one address drift the first time either is edited alone,
//  and the one that drifts is the one nothing fetches, so nothing fails until a release points
//  people at the wrong feed. This is the check the registry's declaration names.

import BBSettings
import BBUpdates
import Testing

@Suite("Update feed")
struct UpdateFeedTests {

  @Test("The settings copy of the feed address is the checker's")
  func declarationsAgree() {
    #expect(UpdateFeed.defaultURL == UpdateChecker.defaultFeedURL)
  }
}
