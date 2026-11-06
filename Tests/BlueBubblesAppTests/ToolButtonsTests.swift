//  ToolButtonsTests
//  Which buttons a program's panel offers, for each place the program can come from.
//
//  A copy installed by a package manager (Tailscale from MacPorts, say) was offered Reinstall
//  and Check for Updates, for a copy BlueBubbles never installed: both act on the managed install, so the first downloaded
//  a second program beside theirs and the second checked a copy that was not in use.

import BBBuiltIns
import BBServiceKit
import Foundation
import Testing

@testable import BBTooling
@testable import BlueBubblesApp

@Suite("Program panel buttons")
struct ToolButtonsTests {

  private static let path = "/opt/example/bin/tailscaled"

  private func status(
    _ origin: ToolOrigin,
    copy: ToolCopyOnThisMac = .none,
    latest: AvailableUpdate? = nil
  ) -> ToolStatus {
    var state = ToolState(toolID: BuiltInTools.tailscale.id)
    state.latestUpdate = latest
    return ToolStatus(
      descriptor: BuiltInTools.tailscale, state: state, activity: .idle, origin: origin,
      executablePath: origin == .missing ? nil : Self.path, copyOnThisMac: copy,
      preference: .automatic)
  }

  @Test("Nothing installed offers the recommended version, by number")
  func missingOffersInstall() {
    let buttons = status(.missing).buttons
    #expect(buttons.install == .install(version: BuiltInTools.tailscale.recommended?.version))
    #expect(!buttons.checkForUpdates)
    #expect(!buttons.revert)
    #expect(!buttons.installDedicatedCopy)
  }

  @Test("A usable copy being ignored on purpose is offered beside the download")
  func ignoredCopyIsOffered() {
    let buttons = status(.missing, copy: .usable(path: Self.path, version: "1.104.4")).buttons
    #expect(buttons.useCopyOnThisMac == "1.104.4")
  }

  @Test("The copy BlueBubbles installed gets Reinstall and Check for Updates")
  func managedOffersReinstall() {
    let buttons = status(.managed).buttons
    #expect(buttons.install == .reinstall)
    #expect(buttons.checkForUpdates)
    #expect(!buttons.installDedicatedCopy)
    #expect(!buttons.stopUsingChosenCopy)
  }

  @Test("A copy somebody else installed is never offered Reinstall or an update check")
  func somebodyElsesCopy() {
    for origin in [ToolOrigin.discovered, .external] {
      let buttons = status(
        origin, latest: AvailableUpdate(version: "9.9.9", channel: .latest)
      ).buttons
      #expect(buttons.install == .none, "\(origin)")
      #expect(!buttons.checkForUpdates, "\(origin)")
      #expect(!buttons.revert, "\(origin)")
      #expect(!buttons.installNewest, "\(origin)")
      #expect(buttons.installDedicatedCopy, "\(origin)")
    }
    #expect(status(.external).buttons.stopUsingChosenCopy)
    #expect(!status(.discovered).buttons.stopUsingChosenCopy)
  }

  @Test("Nothing is said about the copy on this Mac when it is the one in use")
  func copyInUseIsNotDescribedTwice() {
    let chosen = status(.external, copy: .unreadableVersion(path: Self.path))
    #expect(chosen.copyOnThisMacSummary == nil)
    let elsewhere = status(.managed, copy: .unreadableVersion(path: "/opt/other/tailscaled"))
    #expect(elsewhere.copyOnThisMacSummary != nil)
  }
}
