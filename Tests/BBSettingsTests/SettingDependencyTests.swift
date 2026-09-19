//  SettingDependencyTests
//
//  `SettingPresentation.requires` names another setting by its storage key, so nothing about
//  it is checked by the compiler: a typo, a rename, or a parent that is not a switch all
//  produce a row that is greyed out forever, or one that is never greyed out at all, and
//  neither says anything.
//
//  These are what make the declaration safe to add.

import Foundation
import Testing

@testable import BBPersistence
@testable import BBSettings

@Suite("Setting dependencies")
struct SettingDependencyTests {

  /// Every setting that declares a parent, with it.
  private static var declared: [(child: AnySetting, parentKey: String)] {
    Settings.all.compactMap { setting in
      setting.presentation.requires.map { (setting, $0) }
    }
  }

  @Test("a declared parent exists")
  func parentExists() {
    for (child, parentKey) in Self.declared {
      #expect(
        Settings.setting(forKey: parentKey) != nil,
        "\(child.key) requires \(parentKey), which no setting declares"
      )
    }
  }

  @Test("a parent is a switch")
  func parentIsABool() async throws {
    // Read through the same accessor the row uses. A parent of any other type answers nil
    // for `boolValue`, which the row reads as "satisfied", so the dependency would be
    // declared and silently do nothing.
    let store = try await SettingsStore(
      database: try AppDatabase.inMemory(contributors: [SettingsSchema.self]),
      secrets: InMemorySecretStore()
    )
    for (child, parentKey) in Self.declared {
      guard let parent = Settings.setting(forKey: parentKey) else { continue }
      #expect(
        await parent.read(store).boolValue != nil,
        "\(child.key) requires \(parentKey), which is not a Bool"
      )
    }
  }

  @Test("a parent is reachable")
  func parentIsRenderable() {
    for (child, parentKey) in Self.declared {
      // A child the user can see whose parent they cannot is a dead end: the row says to
      // turn something on and there is nowhere to turn it on.
      guard !child.presentation.isInternal else { continue }
      let parent = Settings.setting(forKey: parentKey)
      #expect(
        parent?.presentation.isInternal == false,
        "\(child.key) requires \(parentKey), which no screen shows"
      )
    }
  }

  @Test("a chain terminates")
  func noCycles() {
    // Chains are allowed (`auto_install_hour` is two links) and cycles are not: the walk in
    // `requirementChain` refuses to loop, so a cycle would not hang the settings screen, but
    // it would silently truncate a row's requirements and draw it live under a switch that
    // is off. The declarations are where that has to be right.
    for (child, parentKey) in Self.declared {
      #expect(child.key != parentKey, "\(child.key) requires itself")
      var seen: Set<String> = [child.key]
      var next: String? = parentKey
      while let key = next {
        #expect(!seen.contains(key), "\(child.key) is in a requirement cycle through \(key)")
        guard !seen.contains(key) else { break }
        seen.insert(key)
        next = Settings.setting(forKey: key)?.presentation.requires
      }
    }
  }

  @Test("the chain is walked whole, nearest first")
  func chainOrder() {
    // The one two-link chain in the registry, and the reason `requirementChain` exists at
    // all: reading only the immediate parent draws the hour live while the switch above it
    // is greyed out.
    let chain = Settings.requirementChain(for: Settings.autoInstallHour.erased)
    #expect(chain.map(\.key) == [Settings.autoInstallUpdates.key, Settings.checkForUpdates.key])
    // A setting with no parent has no chain, which is what keeps this from being a
    // subscription on every row.
    #expect(Settings.requirementChain(for: Settings.socketPort.erased).isEmpty)
  }

  @Test("the switch a row names is the outermost one that is off")
  func blockingRequirementIsClickable() {
    let hour = Settings.autoInstallHour.erased
    let check = Settings.checkForUpdates.key
    let install = Settings.autoInstallUpdates.key

    // Everything on: the row is live and names nothing.
    #expect(Settings.blockingRequirement(for: hour) { _ in true } == nil)

    // Only the outer switch off. Both readings agree here.
    #expect(
      Settings.blockingRequirement(for: hour) { $0 != check }?.key == check)

    // BOTH off, which is the default state of a fresh install and the case that decides
    // this. The nearest unmet switch is Install Updates Automatically, and that row is
    // itself greyed out, so naming it would point at a control the person cannot click.
    #expect(
      Settings.blockingRequirement(for: hour) { _ in false }?.key == check)

    // Only the inner switch off: nothing above it to name.
    #expect(
      Settings.blockingRequirement(for: hour) { $0 != install }?.key == install)

    // A setting with no requirements is never blocked.
    #expect(Settings.blockingRequirement(for: Settings.socketPort.erased) { _ in false } == nil)
  }

  @Test("the FaceTime settings hang off the FaceTime Private API")
  func faceTimeGroup() {
    // The group the feedback was about, pinned by name: a FaceTime setting added later
    // without the declaration is a switch that moves and does nothing, which is the exact
    // shape of the report.
    let expected = Set([
      Settings.faceTimeOutgoingCalls.key,
      Settings.faceTimeIdleCameraOff.key,
      Settings.faceTimeLinkTTLHours.key,
      Settings.faceTimeIncomingHandoff.key,
    ])
    let actual = Set(
      Settings.renderable
        .filter { $0.presentation.requires == Settings.enableFaceTimePrivateAPI.key }
        .map(\.key)
    )
    #expect(actual == expected)
    // And the switch itself is not one of them.
    #expect(Settings.enableFaceTimePrivateAPI.presentation?.requires == nil)
  }

  @Test("two settings that look like they hang off a switch, and do not")
  func deliberateNonDependencies() {
    // Both of these were proposed as dependencies and both would have been wrong. Pinned
    // here rather than left to a comment, because the argument for each is a fact about
    // code somewhere else, and the next person to look at the settings page will see the
    // same shape and reach for the same declaration.

    // A MANUAL check honours the beta channel: `UpdateHandlers` reads this on
    // `GET /server/update/check`, and `UpdatesModel.check(userInitiated:)` on the menu
    // item, neither of which consults `check_for_updates`. Greyed out, the toggle would
    // stop something that still works.
    #expect(Settings.receiveBetaUpdates.presentation?.requires == nil)

    // This writes the private ranges into the ALLOWLIST, and `AccessControl.evaluate`
    // consults `isAlwaysAllowed` BEFORE `policy.isEnabled`, so with rate limiting off it
    // still exempts a LAN address from a block an administrator set by hand.
    #expect(Settings.trustLocalNetwork.presentation?.requires == nil)
  }
}
