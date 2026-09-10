//  CommandOptionTests
//  The command line the headless server presents, and what it turns into.
//
//  Worth testing for one reason: every recovery instruction in the documentation is a flag on
//  this command. `--clear-blocklist` is what an administrator locked out by the rate limiter
//  types, `--set` is how a headless install changes anything at all, and neither has any other
//  way in. A flag that quietly stopped parsing would be found by the person who needed it most,
//  at the moment they needed it.
//
//  `parseOverrides` gets the closest attention because it fails SILENTLY: an entry it cannot
//  read is skipped, so a mistyped `--set` looks exactly like a setting that did not take
//  effect.

import ArgumentParser
import Testing

@testable import BlueBubblesServer

@Suite("Command options")
struct CommandOptionTests {

  /// Parses an argument list the way the binary would.
  private func parse(_ arguments: [String]) throws -> BlueBubblesServerCommand {
    try BlueBubblesServerCommand.parse(arguments)
  }

  @Test("With no arguments the server runs with the UI and no overrides")
  func defaults() throws {
    let command = try parse([])
    #expect(!command.headless)
    #expect(command.config == nil)
    #expect(command.set.isEmpty)
    #expect(!command.migrate)
    #expect(!command.clearBlocklist)
    #expect(!command.removeLegacyCredentials)
    #expect(!command.checkKeychain)
  }

  @Test("Every recovery flag documented for a headless install still parses")
  func recoveryFlags() throws {
    // Named individually rather than in a loop: the point is that THESE spellings work, and
    // a loop over a list built from the same names would pass even if a flag were renamed.
    #expect(try parse(["--headless"]).headless)
    #expect(try parse(["--migrate"]).migrate)
    #expect(try parse(["--clear-blocklist"]).clearBlocklist)
    #expect(try parse(["--remove-legacy-credentials"]).removeLegacyCredentials)
    #expect(try parse(["--check-keychain"]).checkKeychain)
    #expect(try parse(["--config", "/tmp/bb.yml"]).config == "/tmp/bb.yml")
  }

  @Test("An unknown flag is refused rather than ignored")
  func unknownFlagIsRefused() {
    #expect(throws: (any Error).self) { try parse(["--not-a-flag"]) }
  }

  @Test("--set is repeatable and reaches the parser in order")
  func setIsRepeatable() throws {
    let command = try parse(["--set", "socket_port=1234", "--set", "password=hunter2"])
    #expect(command.set == ["socket_port=1234", "password=hunter2"])

    let overrides = BlueBubblesServerCommand.parseOverrides(command.set)
    #expect(overrides == ["socket_port": "1234", "password": "hunter2"])
  }

  @Test("A value containing = keeps everything after the first one")
  func valuesMayContainEquals() {
    // A password, a URL with a query string, a base64 credential: all of them contain `=`,
    // and splitting on every one would truncate the value at the first character that is
    // most likely to appear in exactly the settings that matter.
    let overrides = BlueBubblesServerCommand.parseOverrides([
      "password=a=b=c",
      "server_address=https://x.test/?a=1&b=2",
    ])
    #expect(overrides["password"] == "a=b=c")
    #expect(overrides["server_address"] == "https://x.test/?a=1&b=2")
  }

  @Test("An entry with no = is skipped rather than becoming an empty setting")
  func malformedEntriesAreSkipped() {
    // Skipping is the existing behaviour and the safe one: writing `socket_port` with an
    // empty value would be worse than ignoring it. What this pins is that it does not
    // instead write a key with an empty string.
    let overrides = BlueBubblesServerCommand.parseOverrides(["socket_port", "", "="])
    #expect(overrides["socket_port"] == nil)
    // `=` alone splits into one empty part and is dropped for the same reason.
    #expect(overrides.isEmpty)
  }

  @Test("An empty value is kept, because clearing a setting is a real instruction")
  func emptyValuesAreKept() {
    // `--set password=` is how a scripted install clears one. It has a `=`, so it parses,
    // and the empty string is the value.
    let overrides = BlueBubblesServerCommand.parseOverrides(["password="])
    #expect(overrides["password"] == "")
  }

  @Test("A repeated key takes the last value, the way a command line reads")
  func lastKeyWins() {
    let overrides = BlueBubblesServerCommand.parseOverrides([
      "socket_port=1234", "socket_port=5678",
    ])
    #expect(overrides["socket_port"] == "5678")
  }
}
