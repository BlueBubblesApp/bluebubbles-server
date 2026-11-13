//  MessageSearchPanelTests
//
//  A setting marked `isInternal` is not drawn by the generated settings page. That is the
//  point for bookkeeping like `last_fcm_restart`, and it is a bug for a setting that was
//  moved to a bespoke screen and then dropped from that screen's list: it would still be
//  declared, still be read by the server, still be writable from the command line, and have
//  no control anywhere in the app.
//
//  The same pair `HTTPSettingsPanelTests` holds together, for the section that owns the
//  message search switch.

import BBSettings
import Testing

@testable import BlueBubblesApp

@Suite("Message search panel")
struct MessageSearchPanelTests {

  @Test("the panel draws the search index switch")
  func contents() {
    #expect(MessageSearchPanel.settings.map(\.key) == [Settings.searchIndexEnabled.key])
  }

  /// Without `isInternal` it would render twice: once in Features, once here, and the two
  /// rows would disagree about what is stored the moment one of them was edited.
  @Test("everything the panel draws is off the generated page")
  func notAlsoGenerated() {
    let generated = Settings.renderableSections.flatMap(\.settings).map(\.key)
    for setting in MessageSearchPanel.settings {
      #expect(
        setting.presentation.isInternal,
        "\(setting.key) is drawn by the message search section AND by the generated page"
      )
      #expect(!generated.contains(setting.key))
    }
  }

  /// The section renders each row with `SettingRow`, which needs a declared presentation.
  @Test("every setting the panel draws has something to draw")
  func presentations() {
    for setting in MessageSearchPanel.settings {
      #expect(!setting.presentation.label.isEmpty)
      #expect(setting.presentation.help?.isEmpty == false)
      #expect(Settings.allKeys.contains(setting.key))
    }
  }
}
