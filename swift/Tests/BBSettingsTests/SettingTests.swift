//  SettingTests
//  The descriptor half of settings: the type tag that goes on the wire to storage, and the
//  precedence order of the layers a value can come from.
//
//  Scope, because it is easy to write the wrong test here. A `Setting<T>` is a descriptor —
//  it holds a key, a type and a default, and does nothing. Asserting that it hands back the
//  default it was constructed with, or that `type(of:)` on a `Setting<Int>` says `Int`, tests
//  the Swift type system and passes no matter what the store does; two tests doing exactly
//  that were removed. The coercion behaviour they were reaching for is real and is asserted
//  where it can actually break, against a live store, in `SettingsStoreTests`
//  (`intOneIsNotBoolean`, `startDelayIsDouble`).
//
//  What is left is the part that is not derivable from the declarations: the type tags are
//  persisted verbatim in `app.db`'s `type_tag` column, so renaming one makes every stored row
//  fail its type check on the next read, and the layer ordering is a `Comparable`
//  conformance that decides which of four sources wins.

import Foundation
import Testing

@testable import BBSettings

@Suite("Setting descriptors")
struct SettingTests {
  /// Each type carries an explicit tag so the store never infers a type — the coercion this
  /// replaced read "1" as a Bool and "0.0" as a String.
  ///
  /// The strings themselves are a storage format, not an internal name: `SettingsStore`
  /// writes them to `type_tag` and compares the stored tag against `Value.typeTag` on every
  /// read (`SettingsStore.swift`, `stored.typeTag != Value.typeTag`). Renaming "int" to
  /// "integer" would make every existing row fail that check on the next read of an
  /// upgraded install, which is why they are pinned literally.
  @Test("Type tags are distinct and explicit")
  func typeTags() {
    #expect(Bool.typeTag == "bool")
    #expect(Int.typeTag == "int")
    #expect(Double.typeTag == "double")
    #expect(String.typeTag == "string")
    #expect(Date.typeTag == "date")
  }

  @Test("Later layers win over earlier ones")
  func sourcePrecedence() {
    #expect(SettingSource.declaredDefault < SettingSource.persistedStore)
    #expect(SettingSource.persistedStore < SettingSource.configFile)
    #expect(SettingSource.configFile < SettingSource.commandLine)
  }
  /// `launch-agent` was a third `auto_start_method` that never registered anything. Rows
  /// holding it are still out there, and what they decode to is a decision rather than an
  /// implementation detail — `.none` would quietly answer a question the user had already
  /// answered, so the intent is carried to the option that works.
  @Test("The retired launch-agent value reads as a login item")
  func retiredLaunchAgentMapsToLoginItem() {
    #expect(AutoStartMethod.parse(loose: "launch-agent") == .loginItem)
    #expect(AutoStartMethod.parse(loose: "login-item") == .loginItem)
    #expect(AutoStartMethod.parse(loose: "none") == AutoStartMethod.none)
    #expect(AutoStartMethod.parse(loose: "nonsense") == nil, "an unknown value still fails")
    // And it is not offered again: a picker showing it would let someone choose a value
    // whose only meaning is historical.
    #expect(AutoStartMethod.choices.contains(.loginItem))
    #expect(AutoStartMethod.choices.count == 2)
  }
}
