//  WhatsNewTests
//  The first start after an update says so, and nothing else does.

import Testing

@testable import BlueBubblesApp

@Suite("What's new")
struct WhatsNewTests {

  @Test("A newer version than last time is announced, with its notes page")
  func upgradeIsAnnounced() throws {
    let notice = try #require(WhatsNew.notice(previous: "1.2.0", current: "1.3.0"))
    #expect(notice.title.contains("1.3.0"))
    #expect(notice.body.contains("1.2.0"))
    #expect(notice.notesURL.hasSuffix("/releases/tag/v1.3.0"))
  }

  @Test("A fresh install, the same version, and a rollback say nothing")
  func silentCases() {
    #expect(WhatsNew.notice(previous: nil, current: "1.3.0") == nil)
    #expect(WhatsNew.notice(previous: "", current: "1.3.0") == nil)
    #expect(WhatsNew.notice(previous: " 1.3.0 ", current: "1.3.0") == nil)
    #expect(WhatsNew.notice(previous: "1.4.0", current: "1.3.0") == nil)
  }

  @Test("A beta counts as an update from the release before it")
  func betaIsAnUpdate() {
    #expect(WhatsNew.notice(previous: "1.2.0", current: "1.3.0-beta.1") != nil)
    #expect(WhatsNew.notice(previous: "1.3.0-beta.1", current: "1.3.0") != nil)
  }
}
