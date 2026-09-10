//  HTTPSettingsPanelTests
//
//  A setting marked `isInternal` is not drawn by the generated settings page. That is the
//  point for bookkeeping like `last_fcm_restart`, and it is a bug for a setting that was
//  moved to a bespoke screen and then dropped from that screen's list: it would still be
//  declared, still be read by the server, still be writable from the command line, and have
//  no control anywhere in the app.
//
//  These hold the two halves together.

import BBSettings
import Testing

@testable import BlueBubblesApp

@Suite("HTTP settings panel")
struct HTTPSettingsPanelTests {

  @Test("the panel draws the listener's two settings")
  func contents() {
    let keys = HTTPSettingsPanel.settings.map(\.key)
    #expect(keys == [Settings.bindAddress.key, Settings.useCustomCertificate.key])
  }

  /// If either lost its `isInternal` it would render twice (once in the Connection form and
  /// once in the panel) and the two rows would disagree about what is stored the moment one
  /// of them was edited.
  @Test("everything the panel draws is off the generated page")
  func notAlsoGenerated() {
    for setting in HTTPSettingsPanel.settings {
      #expect(
        setting.presentation.isInternal,
        "\(setting.key) is drawn by the HTTP panel AND by the generated settings page"
      )
    }
    let generated = Settings.renderableSections.flatMap(\.settings).map(\.key)
    for setting in HTTPSettingsPanel.settings {
      #expect(!generated.contains(setting.key))
    }
  }

  /// The panel renders each row with `SettingRow`, which needs a declared presentation:
  /// a label to head the row and, for `bind_address`, the `.custom` control that selects
  /// the live address picker.
  @Test("every setting the panel draws has something to draw")
  func presentations() {
    for setting in HTTPSettingsPanel.settings {
      #expect(!setting.presentation.label.isEmpty)
      #expect(Settings.allKeys.contains(setting.key))
    }
  }
}
