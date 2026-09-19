//  HTTPListenerReconfigurationTests
//  Changing what the listener binds to rebuilds the listener.
//
//  The listener's address, port and TLS are read ONCE, in `start`. A change to any of them
//  therefore does nothing at all unless the service is restarted, and a setting that saves
//  successfully and does nothing is the failure `WatchedSettingsTests` was written for: the
//  user moves "Listen On" from Loopback to All interfaces, the row saves, the switch looks
//  applied, and the server is still bound to 127.0.0.1 until the next launch.
//
//  It works today, through the manifest: `readSettings` names the four keys, the default
//  `watchedSettings` is derived from it, and `apply` returns `.restart` for anything it
//  watches. That is a chain of three defaults, none of which is visibly about the HTTP
//  listener, so this pins the OUTCOME rather than any one link.
//
//  See `.claude/docs/architecture.md` and `HTTPService.liveKeys`.

import BBPrivateAPIContract
import BBServiceKit
import BBSettings
import Foundation
import Testing

@testable import BBBuiltIns
@testable import BlueBubblesServerCore

@Suite("HTTP listener reconfiguration")
struct HTTPListenerReconfigurationTests {

  /// Everything that decides what the listener binds to, and what the password kicks.
  ///
  /// Each of these must rebuild the listener. `bind_address` is the one this suite is named
  /// for; the rest travel with it because they are read at the same moment and would fail
  /// the same way.
  static let mustRestart: [(key: String, why: String)] = [
    (Settings.bindAddress.key, "which interface the listener accepts connections on"),
    (Settings.socketPort.key, "which port it accepts them on"),
    (Settings.useCustomCertificate.key, "whether it terminates TLS"),
    (Settings.password.key, "clients authenticated with the old one must be kicked"),
  ]

  /// Read by this service and deliberately NOT watched, because this service WRITES them.
  ///
  /// `ServiceManifest.watchedSettingKeys` subtracts a service's own writes, which is the
  /// anti-loop rule: `TLSProvisioning` records where a certificate came from and when it
  /// expires as it generates one, and watching those would restart the listener on its own
  /// bookkeeping, which would generate again. They are in `readSettings` because the
  /// renewer reads them at start; a certificate change that matters travels with
  /// `use_custom_certificate`, which IS watched.
  static let readButNotWatched = [
    Settings.tlsCertificateOrigin.key, Settings.tlsCertificateExpiresAt.key,
  ]

  @Test("a setting this service writes is not one it restarts on")
  func ownWritesDoNotLoop() {
    for key in Self.readButNotWatched {
      #expect(!HTTPService.watchedSettings.contains(key))
      #expect(HTTPService.reloadAction(for: SettingsChange(changedKeys: [key])) == .none)
    }
  }

  @Test("every listener setting is watched")
  func watchedSetIsComplete() {
    for entry in Self.mustRestart {
      #expect(
        HTTPService.watchedSettings.contains(entry.key),
        Comment(
          rawValue: "\(entry.key) decides \(entry.why) and is not watched, so "
            + "changing it would apply only on the next launch")
      )
    }
  }

  @Test("a change to any of them restarts the service")
  func eachOneRestarts() {
    for entry in Self.mustRestart {
      let action = HTTPService.reloadAction(for: SettingsChange(changedKeys: [entry.key]))
      #expect(
        action == .restart,
        Comment(
          rawValue: "\(entry.key) decides \(entry.why); \(action) leaves the listener on "
            + "the old value")
      )
    }
  }

  /// The one exemption, and why it is not a hole.
  @Test("server_address alone does not restart")
  func publishedAddressIsLive() {
    // Written by whichever connection method is running, on every connect and reconnect,
    // and the proxies depend on this service. Restarting on it restarted them, which
    // reconnected the tunnel, which published again: measured at about twenty cloudflared
    // respawns a second, indefinitely. See `HTTPService.liveKeys`.
    #expect(
      HTTPService.reloadAction(for: SettingsChange(changedKeys: [Settings.serverAddress.key]))
        == .none)

    // But it must not MASK a real change travelling in the same batch: a write that moves
    // the bind address and republishes the address in one transaction still restarts.
    #expect(
      HTTPService.reloadAction(
        for: SettingsChange(changedKeys: [
          Settings.serverAddress.key, Settings.bindAddress.key,
        ])) == .restart)
  }

  @Test("a setting this service does not read changes nothing")
  func unrelatedSettingsAreIgnored() {
    #expect(
      HTTPService.reloadAction(for: SettingsChange(changedKeys: [Settings.logLevel.key]))
        == .none)
    #expect(
      HTTPService.reloadAction(for: SettingsChange(changedKeys: [Settings.dbPollInterval.key]))
        == .none)
  }

  /// `bind_address` must stay wide by default.
  ///
  /// A server nobody can reach from another device is the failure this default prevents, and
  /// it is the reference's default too. Loopback is the right answer for a tunnel user and
  /// is one deliberate choice away in the picker; it must never be what an install starts on.
  @Test("the default is every interface")
  func defaultIsAllInterfaces() {
    #expect(Settings.bindAddress.defaultValue == "0.0.0.0")
  }
}
