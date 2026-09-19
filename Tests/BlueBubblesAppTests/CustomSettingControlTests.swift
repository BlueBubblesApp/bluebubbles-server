//  CustomSettingControlTests
//  Every setting that says it is rendered by a bespoke view has one.
//
//  The failure this catches is the project's recurring one: a setting that exists, saves, is
//  read by the server, and is drawn by nothing: here, a `.custom` presentation that falls
//  through to a read-only line because no case names its key.

import BBSettings
import Testing

@testable import BlueBubblesApp

@Suite("Custom setting controls")
struct CustomSettingControlTests {

  @Test("Every .custom setting in the registry resolves to a control")
  func everyCustomSettingHasAControl() {
    for setting in Settings.renderable {
      guard case .custom = setting.presentation.control else { continue }
      #expect(
        CustomSettingControl(key: setting.key) != nil,
        "'\(setting.key)' is declared .custom and would render as read-only text"
      )
    }
  }

  @Test("Every control names a setting that is actually declared .custom")
  func everyControlHasASetting() {
    // The other direction: a control left behind after its setting was removed or changed
    // to a generated one is a case nothing can reach.
    let custom = Set(
      Settings.renderable.compactMap { setting -> String? in
        guard case .custom = setting.presentation.control else { return nil }
        return setting.key
      })
    for control in CustomSettingControl.allCases {
      #expect(
        custom.contains(control.key),
        "\(control) draws '\(control.key)', which is not declared .custom"
      )
    }
  }
}
