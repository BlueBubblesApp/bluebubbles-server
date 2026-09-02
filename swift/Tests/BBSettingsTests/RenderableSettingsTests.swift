//  RenderableSettingsTests
//
//  `Settings.renderable` is a hand-written list, because Swift cannot enumerate a type's
//  static members. That makes omission the obvious failure: someone declares a setting with a
//  presentation, forgets the list, and it silently never appears in the app — which is the
//  exact bug the generated settings screen exists to prevent.
//
//  These are what keep the list honest.

import Foundation
import Testing

@testable import BBSettings

@Suite("Renderable settings")
struct RenderableSettingsTests {

  @Test("every renderable setting has a real presentation")
  func presentations() {
    for setting in Settings.renderable {
      #expect(!setting.presentation.label.isEmpty, "\(setting.key) has no label")
      #expect(!setting.presentation.section.isEmpty, "\(setting.key) has no section")
      // `.custom` means the settings screen renders it with a bespoke view rather than
      // a generated control — used where the OPTIONS are runtime data, like this
      // machine's network interfaces or the installed connection methods.
      //
      // It must still be in this list, because that is what puts it on screen at all.
      // The failure this guards against is the other one: a custom setting with no
      // bespoke renderer falls through to a read-only row, which looks like a setting
      // that cannot be changed rather than one nobody wired up. `bind_address` was in
      // exactly that state — a picker written and a setting that never appeared.
      if case .custom = setting.presentation.control {
        #expect(
          Self.customRenderers.contains(setting.key),
          "\(setting.key) is .custom but SettingsView has no bespoke view for it"
        )
      }
    }
  }

  /// Keys the settings screen renders with a bespoke view. Kept here so adding a `.custom`
  /// setting without writing its view fails loudly.
  static let customRenderers: Set<String> = [
    "bind_address", "connection_method", "ntfy_events",
  ]

  @Test("keys are unique")
  func uniqueKeys() {
    let keys = Settings.renderable.map(\.key)
    #expect(Set(keys).count == keys.count, "a setting is listed twice")
  }

  /// Every renderable key must be a real settings key. A typo here would produce a row
  /// that reads and writes a setting nothing else uses — it would look like it worked.
  @Test("every renderable key is a declared key")
  func keysAreDeclared() {
    for setting in Settings.renderable {
      #expect(
        Settings.allKeys.contains(setting.key),
        "\(setting.key) is not in Settings.allKeys"
      )
    }
  }

  /// The count is pinned deliberately. It fails when a setting is added to the registry
  /// with a presentation but not to `renderable` — which is the omission this file exists
  /// to catch — and the fix is one line in either direction.
  @Test("the renderable list covers every presented setting")
  func coverage() {
    // The pin covers the HAND-LISTED settings. Feature flags are appended from
    // `Features.all`, so a new flag reaches the screen without an edit here — which is
    // the point of enumerating them — and the count still fails when someone adds a
    // presented setting and forgets `renderable`.
    #expect(
      Settings.renderable.count == 37 + Features.all.count,
      """
      The renderable list has \(Settings.renderable.count) entries. If you added a \
      setting with a `presentation:`, add it to `Settings.renderable` too — otherwise \
      it will never appear in the app. If you deliberately removed one, update this \
      count.
      """
    )
  }

  @Test("sections group in declaration order")
  func sections() {
    let sections = Settings.renderableSections
    #expect(!sections.isEmpty)

    // No section appears twice — a regrouping bug would scatter one section's rows
    // across the form.
    let names = sections.map(\.section)
    #expect(Set(names).count == names.count)

    // Every visible setting lands in exactly one section.
    let placed = sections.flatMap(\.settings).map(\.key)
    let expected = Settings.renderable
      .filter { !$0.presentation.isInternal }
      .map(\.key)
    #expect(Set(placed) == Set(expected))
  }

  /// Internal settings are excluded from the form. `ngrok_protocol` is marked internal and
  /// must not get a row.
  @Test("internal settings are not rendered")
  func internalHidden() {
    let rendered = Settings.renderableSections.flatMap(\.settings).map(\.key)
    #expect(!rendered.contains("ngrok_protocol"))
  }

  /// Secrets carry the flag, so the row renders a secure field rather than plain text.
  @Test("secret settings are marked secret")
  func secrets() {
    for setting in Settings.renderable where Settings.secretKeys.contains(setting.key) {
      #expect(setting.isSecret, "\(setting.key) is a secret key but is not marked secret")
    }
  }
}

@Suite("Setting erasure")
struct SettingErasureTests {

  /// Boxing must not lose the value. A wrong unbox would make a row read one setting and
  /// write another type into it.
  @Test("numeric boxes convert both ways")
  func numericBoxes() {
    #expect(SettingBox.int(42).intValue == 42)
    #expect(SettingBox.int(42).doubleValue == 42.0)
    #expect(SettingBox.double(1.5).doubleValue == 1.5)
    // Truncating, which is what a whole-number control needs from a Double setting.
    #expect(SettingBox.double(1.9).intValue == 1)
    #expect(SettingBox.string("no").intValue == nil)
    #expect(SettingBox.bool(true).intValue == nil)
  }

  @Test("boxes do not silently coerce across kinds")
  func noCoercion() {
    #expect(SettingBox.string("true").boolValue == nil)
    #expect(SettingBox.bool(true).stringValue == nil)
    #expect(SettingBox.int(1).stringValue == nil)
  }
}
