import Foundation
import Testing

@testable import BBSettings

@Suite("Setting descriptors")
struct SettingTests {
  /// Each type carries an explicit tag so the store never infers a type. These are the
  /// exact cases the current regex coercion gets wrong.
  @Test("Type tags are distinct and explicit")
  func typeTags() {
    #expect(Bool.typeTag == "bool")
    #expect(Int.typeTag == "int")
    #expect(Double.typeTag == "double")
    #expect(String.typeTag == "string")
    #expect(Date.typeTag == "date")
  }

  /// In the current server a numeric setting whose value is 0 or 1 comes back as a Bool,
  /// which is why start_delay is defaulted to the string "0.0" to dodge the coercion.
  @Test("An Int setting of 1 stays an Int")
  func intOneIsNotBool() {
    let setting = Setting<Int>("db_poll_interval", default: 1)
    #expect(type(of: setting.defaultValue) == Int.self)
    #expect(Int.typeTag != Bool.typeTag)
  }

  /// start_delay is a real Double now, not a string chosen to survive parsing.
  @Test("start_delay is a Double")
  func startDelayIsDouble() {
    let setting = Setting<Double>("start_delay", default: 0)
    #expect(setting.defaultValue == 0.0)
  }

  @Test("Later layers win over earlier ones")
  func sourcePrecedence() {
    #expect(SettingSource.declaredDefault < SettingSource.persistedStore)
    #expect(SettingSource.persistedStore < SettingSource.configFile)
    #expect(SettingSource.configFile < SettingSource.commandLine)
  }
}
