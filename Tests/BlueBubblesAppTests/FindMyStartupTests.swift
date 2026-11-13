//  FindMyStartupTests
//  When the app may open FindMy on someone's Mac, which is: rarely.
//
//  Opening another application unasked is the kind of thing a server should have a reason
//  for, and this one had the weakest possible reason — a setting named `open_findmy_on_startup`
//  that defaulted to on, and a bare `if` that launched the app. It was a mis-transcription:
//  the reference's key of that name gates whether a FRIENDS refresh may open the app, is read
//  only when the friends cache is empty, and covers a macOS range that ends below this
//  server's floor.
//
//  The two conditions are asserted here because neither is visible from the call site, and
//  because the second is the sort of guard that reads as redundant and gets deleted:
//
//  1. The setting, which now defaults OFF.
//  2. Whether the cache the launch refreshes can be read back at all. Apple encrypted
//     `Devices.data` in Sequoia, so on 15 and newer the launch opens an app and changes
//     nothing any route can serve.
//
//  What it does NOT gate is friends, and that is worth knowing before someone "fixes" this by
//  widening it: `IMFMFSession` is an IMCore class live in Messages.app from launch (see
//  `Helper/BlueBubblesHelper/FindMyBridge.swift`), so every friends call works with FindMy.app
//  closed. Devices are not reachable that way and never will be through this mechanism —
//  `FMIPCore` is pure Swift with no Objective-C method list at all, measured in
//  `docs/PRIVATE_API_SURFACE.md` § The Swift wall.

import BBSettings
import Testing

@testable import BlueBubblesApp

@Suite("FindMy startup")
struct FindMyStartupTests {

  @Test("Both conditions are required, and neither alone is enough")
  func bothConditionsAreRequired() {
    #expect(AppBehaviourPolicy.shouldOpenFindMy(enabled: true, cacheIsReadable: true))

    // The switch is off: the ordinary case, and the default since the launch stopped being
    // something a fresh install does.
    #expect(!AppBehaviourPolicy.shouldOpenFindMy(enabled: false, cacheIsReadable: true))

    // Opted in, on Sequoia or newer. THIS is the case the guard exists for: the person asked
    // for it, and honouring the request would open their FindMy on every start to refresh a
    // file that `/findmy/devices` cannot read.
    #expect(!AppBehaviourPolicy.shouldOpenFindMy(enabled: true, cacheIsReadable: false))

    #expect(!AppBehaviourPolicy.shouldOpenFindMy(enabled: false, cacheIsReadable: false))
  }

  @Test("The setting a fresh install gets does not open anything")
  func theDefaultDoesNotLaunch() {
    // Asserted through the POLICY rather than by reading `defaultValue` back off the
    // descriptor. `SettingTests` explains why the latter is worthless — it restates the
    // declaration and passes whatever the app does with it — whereas this fails if either
    // the default flips or the condition stops being consulted.
    #expect(
      !AppBehaviourPolicy.shouldOpenFindMy(
        enabled: Settings.openFindMyOnStartup.defaultValue, cacheIsReadable: true),
      "a fresh install opens FindMy on startup")
  }
}
