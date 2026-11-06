//  SettingSectionTests
//  Every section has words, and every rendered section is one of the cases.

import Testing

@testable import BBSettings

@Suite("Setting sections")
struct SettingSectionTests {

  @Test("every section has a title and a summary")
  func words() {
    for section in SettingSection.allCases {
      #expect(!section.title.isEmpty, "\(section) has no title")
      #expect(!section.summary.isEmpty, "\(section) has no summary")
    }
  }

  @Test("titles are distinct")
  func distinctTitles() {
    let titles = SettingSection.allCases.map(\.title)
    #expect(Set(titles).count == titles.count)
  }
}
