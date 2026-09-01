//  LaunchOptionsTests
//
//  These exist because the app previously accepted every one of these arguments and applied
//  none of them: it built `ServerComposition.Options()` with no values at all, so an operator
//  passing `--set password=…` got a server running on its stored settings with no indication
//  anything had been ignored. A login item, which is configured only by its arguments, would
//  have been silently misconfigured.

import Testing

@testable import BlueBubblesApp

@Suite("Launch options")
struct LaunchOptionsTests {

  @Test("headless is recognised")
  func headless() {
    #expect(LaunchOptions.parse(["app", "--headless"]).isHeadless)
    #expect(!LaunchOptions.parse(["app"]).isHeadless)
  }

  @Test("repeated --set collects every override")
  func overrides() {
    let options = LaunchOptions.parse([
      "app", "--set", "socket_port=1234", "--set", "log_level=debug",
    ])
    #expect(options.overrides == ["socket_port": "1234", "log_level": "debug"])
  }

  /// A password or a base64 token routinely contains `=`. Splitting on every `=` would
  /// truncate it, and the server would then reject the password the operator thought they
  /// had set.
  @Test("a value containing = survives")
  func equalsInValue() {
    let options = LaunchOptions.parse(["app", "--set", "password=ab=cd=="])
    #expect(options.overrides["password"] == "ab=cd==")
  }

  @Test("a config path is read")
  func configPath() {
    #expect(LaunchOptions.parse(["app", "--config", "/tmp/x.yml"]).configPath == "/tmp/x.yml")
  }

  /// `--config --headless` must not set the path to "--headless" and then fail later with
  /// a puzzling "no such file".
  @Test("a flag is not consumed as a missing value")
  func missingValue() {
    let options = LaunchOptions.parse(["app", "--config", "--headless"])
    #expect(options.configPath == nil)
    #expect(options.isHeadless)
  }

  /// macOS passes its own arguments to a bundled app — `-psn_0_…` when launched from
  /// Finder, `-NSDocumentRevisionsDebugMode` under a debugger. Treating an unknown
  /// argument as an error would make the app refuse to open when double-clicked.
  @Test("unknown arguments are ignored")
  func unknownArguments() {
    let options = LaunchOptions.parse([
      "app", "-psn_0_12345", "-NSDocumentRevisionsDebugMode", "YES",
      "--headless", "--set", "socket_port=99",
    ])
    #expect(options.isHeadless)
    #expect(options.overrides == ["socket_port": "99"])
  }

  @Test("a malformed --set is dropped rather than crashing")
  func malformedSet() {
    #expect(LaunchOptions.parse(["app", "--set", "novalue"]).overrides.isEmpty)
    #expect(LaunchOptions.parse(["app", "--set"]).overrides.isEmpty)
  }

  @Test("everything together")
  func combined() {
    let options = LaunchOptions.parse([
      "app", "--headless", "--config", "/etc/bb.yml", "--set", "socket_port=1234",
    ])
    #expect(options.isHeadless)
    #expect(options.configPath == "/etc/bb.yml")
    #expect(options.overrides["socket_port"] == "1234")

    let composed = options.compositionOptions
    #expect(composed.headless)
    #expect(composed.configPath == "/etc/bb.yml")
    #expect(composed.overrides["socket_port"] == "1234")
  }
}
