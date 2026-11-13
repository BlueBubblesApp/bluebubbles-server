//  ZrokErrorTests
//  Which zrok failures are zrok's end, and so retried until it comes back.
//
//  A table, because each answer is a decision with a cost on both sides: retrying a refusal
//  only a person can fix re-raises the same notice, and not retrying an outage leaves the
//  server unreachable until somebody restarts it. `reserveFailed` is the one that must never
//  be retried: the reserve SUCCEEDED, and trying again reserves another share on the user's
//  account every time.

import Testing

@testable import BBProxy

@Suite("zrok failures")
struct ZrokErrorTests {

  @Test("A command that ran and failed, or did not finish, is zrok's end")
  func providerSide() {
    #expect(ZrokError.commandFailed(command: "enable", output: "connection refused").isProviderSide)
    #expect(ZrokError.command(.timedOut(tool: "zrok", command: "overview")).isProviderSide)
  }

  @Test("Anything a person has to fix is not retried")
  func needsPerson() {
    #expect(!ZrokError.invalidAccountToken.isProviderSide)
    #expect(!ZrokError.notEnabled.isProviderSide)
    #expect(!ZrokError.reserveFailed(output: "").isProviderSide)
    #expect(!ZrokError.command(.executableMissing(tool: "zrok", path: "/x")).isProviderSide)
    #expect(!ZrokError.command(.launchFailed(tool: "zrok", reason: "denied")).isProviderSide)
  }
}
