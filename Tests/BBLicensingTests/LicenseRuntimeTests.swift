//  LicenseRuntimeTests
//  Storage, the issuer exchange, and what one refresh does.
//
//  The assertion worth having is that a FAILED refresh keeps the token it already had. That is
//  the entire purpose of the seven-day window: a Mac that cannot reach the issuer for an
//  afternoon must not lose the entitlement it is holding, and the easy bug is a refresh path
//  that clears the cache before it knows whether it can replace it.

import BBCore
import BBLicense
import BBPersistence
import BBSettings
import BBTestSupport
import Crypto
import Foundation
import Testing

@testable import BBLicensing

@Suite("License runtime")
struct LicenseRuntimeTests {

  static let machine = MachineFingerprint.of(seed: "test-mac")
  static let start = Date(timeIntervalSince1970: 1_700_000_000)
  static let signing = Curve25519.Signing.PrivateKey()

  static func store() async throws -> SettingsStore {
    try await TestSettings.store()
  }

  /// A token the way the issuer will mint one.
  static func mint(
    tier: String = "pro", rank: Int = 1, machine: String = machine,
    expires: Date, subscriptionEnds: Date? = nil
  ) throws -> String {
    var claims: [String: Any] = [
      "v": 1, "sub": "cus_1", "tier": tier, "rank": rank, "feats": [],
      "machine": machine, "iat": start.timeIntervalSince1970,
      "exp": expires.timeIntervalSince1970, "jti": "tok_1",
    ]
    if let ends = subscriptionEnds { claims["sub_end"] = ends.timeIntervalSince1970 }
    let header = try JSONSerialization.data(withJSONObject: ["alg": "EdDSA", "typ": "JWT"])
    let payload = try JSONSerialization.data(withJSONObject: claims)
    let signing =
      "\(Base64URL.encode(header))"
      + ".\(Base64URL.encode(payload))"
    let signature = try Self.signing.signature(for: Data(signing.utf8))
    return "\(signing).\(Base64URL.encode(signature))"
  }

  static func verify(_ token: String) throws -> EntitlementToken {
    try TokenVerifier.verify(token, publicKey: signing.publicKey)
  }

  /// A transport that answers with whatever the test wants, and never touches the network.
  ///
  /// The body is serialised UP FRONT rather than captured: `[String: Any]` is not `Sendable`,
  /// and the transport is a `@Sendable` closure.
  static func transport(status: Int = 200, body: [String: Any]) -> EntitlementClient.Transport {
    let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    return { request in
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      return (data, response)
    }
  }

  static func runtime(
    settings: SettingsStore, clock: ManualClock,
    transport: @escaping EntitlementClient.Transport,
    auditor: (any LicenseAuditing)? = nil
  ) -> LicenseRuntime {
    LicenseRuntime(
      store: LicenseStore(settings: settings),
      client: EntitlementClient(
        endpoint: "https://issuer.example/v1", serverVersion: "test", transport: transport),
      machine: machine, clock: clock, verify: verify, auditor: auditor
    )
  }

  // MARK: - Storage

  @Test("A stored token comes back, and clearing removes everything")
  func storeRoundTrip() async throws {
    let settings = try await Self.store()
    let store = LicenseStore(settings: settings)
    let token = try Self.mint(expires: Self.start.addingTimeInterval(86_400))

    #expect(await store.hasKey() == false)
    try await settings.set(Settings.licenseKey, to: "LK-123")
    #expect(await store.hasKey())

    try await store.store(token: token, checkedAt: Self.start)
    let loaded = await store.load(verifier: Self.verify)
    #expect(loaded.token?.subject == "cus_1")
    #expect(loaded.lastRefresh == Self.start)
    #expect(loaded.isRevoked == false)

    try await store.clear()
    #expect(await store.hasKey() == false)
    #expect(await store.load(verifier: Self.verify).token == nil)
  }

  /// A cache, not a source of truth. A token that no longer verifies must not stop the
  /// server: the next refresh replaces it.
  @Test("An unverifiable cached token loads as absent rather than throwing")
  func corruptCacheIsAbsent() async throws {
    let settings = try await Self.store()
    try await settings.set(Settings.licenseToken, to: "not.a.token")
    let loaded = await LicenseStore(settings: settings).load(verifier: Self.verify)
    #expect(loaded.token == nil)
  }

  @Test("Revocation is persisted, and keeps the token as evidence")
  func revocationPersists() async throws {
    let settings = try await Self.store()
    let store = LicenseStore(settings: settings)
    try await store.store(
      token: try Self.mint(expires: Self.start.addingTimeInterval(86_400)), checkedAt: Self.start)
    try await store.markRevoked()

    let loaded = await store.load(verifier: Self.verify)
    #expect(loaded.isRevoked)
    #expect(loaded.token != nil)
  }

  // MARK: - Priming

  /// The gate must not depend on a schedule having run. `LicenseService.start()` used to be
  /// the only caller of `reload()`, so a runtime nobody had started answered "no license"
  /// over a valid token on disk, and the first gated request after launch was refused.
  @Test("A stored token is entitled on the first read, with nothing having reloaded")
  func primesFromDisk() async throws {
    let settings = try await Self.store()
    try await settings.set(Settings.licenseKey, to: "LK-123")
    try await LicenseStore(settings: settings).store(
      token: try Self.mint(expires: Self.start.addingTimeInterval(7 * 86_400)),
      checkedAt: Self.start)

    let runtime = Self.runtime(
      settings: settings, clock: ManualClock(Self.start),
      transport: { _ in
        Issue.record("priming is a disk read, never an exchange")
        throw CancellationError()
      }
    )
    #expect(await runtime.status().tier == .pro)
    #expect(await runtime.status().refusal(forRequired: .pro) == nil)
  }

  /// And a fresh install is `.none` on the first read too, rather than a placeholder that
  /// happens to spell the same.
  @Test("An empty store primes to no license")
  func primesToNone() async throws {
    let settings = try await Self.store()
    let runtime = Self.runtime(
      settings: settings, clock: ManualClock(Self.start),
      transport: { _ in throw CancellationError() })
    #expect(await runtime.status() == .none)
  }

  // MARK: - Announcing

  /// The service republishes its health on each of these; without them, a key redeemed
  /// from the Subscription page left Home saying the license service could not be reached.
  @Test("A reload that moves the status is announced, and one that does not is silent")
  func announcesMovedStatus() async throws {
    let settings = try await Self.store()
    let runtime = Self.runtime(
      settings: settings, clock: ManualClock(Self.start),
      transport: { _ in throw CancellationError() })
    var changes = await runtime.statusChanges().makeAsyncIterator()

    await runtime.reload()
    #expect(await changes.next() == LicenseStatus.none)

    // The same answer again: nothing to announce. If it were announced, the read after the
    // real change below would see this duplicate first.
    await runtime.reload()

    try await settings.set(Settings.licenseKey, to: "LK-123")
    try await LicenseStore(settings: settings).store(
      token: try Self.mint(expires: Self.start.addingTimeInterval(7 * 86_400)),
      checkedAt: Self.start)
    await runtime.reload()
    #expect(await changes.next()?.tier == .pro)
  }

  // MARK: - The exchange

  @Test("No key means no request and no failure")
  func noKey() async throws {
    let settings = try await Self.store()
    let runtime = Self.runtime(
      settings: settings, clock: ManualClock(Self.start),
      transport: { _ in
        Issue.record("must not reach the issuer with no key")
        throw CancellationError()
      }
    )
    #expect(await runtime.refresh() == .noKey)
    #expect(await runtime.status() == .none)
  }

  @Test("A successful exchange becomes an active entitlement")
  func refreshes() async throws {
    let settings = try await Self.store()
    try await settings.set(Settings.licenseKey, to: "LK-123")
    let token = try Self.mint(expires: Self.start.addingTimeInterval(7 * 86_400))
    let runtime = Self.runtime(
      settings: settings, clock: ManualClock(Self.start),
      transport: Self.transport(body: ["token": token]))

    #expect(await runtime.refresh() == .refreshed(.pro))
    #expect(await runtime.status().tier == .pro)
    #expect(await runtime.status().refusal(forRequired: .pro) == nil)
  }

  /// The issuer mints a token for an ended subscription so the page can say when it ended.
  /// Before this was pinned, that token came back as `.refreshed(.pro)`: the service logged
  /// "Subscription confirmed" and the page showed nothing, over routes answering 402.
  @Test("A token for an ended subscription is not reported as success")
  func endedSubscriptionIsNotEntitled() async throws {
    let settings = try await Self.store()
    try await settings.set(Settings.licenseKey, to: "LK-123")
    let ended = Self.start.addingTimeInterval(-86_400)
    let token = try Self.mint(
      expires: Self.start.addingTimeInterval(7 * 86_400), subscriptionEnds: ended)
    let runtime = Self.runtime(
      settings: settings, clock: ManualClock(Self.start),
      transport: Self.transport(body: ["token": token]))

    #expect(await runtime.refresh() == .notEntitled(.expired(at: ended)))
    #expect(await runtime.status().refusal(forRequired: .pro)?.reason == "license_expired")
  }

  @Test("A token for another Mac is not reported as success either")
  func otherMachineIsNotEntitled() async throws {
    let settings = try await Self.store()
    try await settings.set(Settings.licenseKey, to: "LK-123")
    let token = try Self.mint(
      machine: "someone-elses-mac", expires: Self.start.addingTimeInterval(7 * 86_400))
    let runtime = Self.runtime(
      settings: settings, clock: ManualClock(Self.start),
      transport: Self.transport(body: ["token": token]))

    #expect(await runtime.refresh() == .notEntitled(.machineMismatch))
  }

  @Test("A revoking issuer is persisted and refuses")
  func revoked() async throws {
    let settings = try await Self.store()
    try await settings.set(Settings.licenseKey, to: "LK-123")
    let token = try Self.mint(expires: Self.start.addingTimeInterval(7 * 86_400))
    let runtime = Self.runtime(
      settings: settings, clock: ManualClock(Self.start),
      transport: Self.transport(body: ["token": token, "revoked": true]))

    #expect(await runtime.refresh() == .revoked)
    #expect(await runtime.status().refusal(forRequired: .pro)?.reason == "license_revoked")
    #expect(await settings.get(Settings.licenseRevoked))
  }

  /// The one that matters. A refresh that cannot reach the issuer keeps what it had.
  /// The store refusing the write must not leave a revoked license granting: the issuer
  /// has answered, and a refunded customer keeping Pro until a database recovers is the
  /// failure. A trigger makes exactly that one write fail.
  @Test("A revocation the store refuses to record still refuses this run")
  func unpersistedRevocationStillRefuses() async throws {
    let database = try AppDatabase.inMemory(contributors: [SettingsSchema.self])
    let settings = try await TestSettings.store(database: database)
    let clock = ManualClock(Self.start)
    let token = try Self.mint(expires: Self.start.addingTimeInterval(7 * 86_400))
    try await settings.set(Settings.licenseKey, to: "LK-123")
    try await LicenseStore(settings: settings).store(token: token, checkedAt: Self.start)
    let revokedKey = Settings.licenseRevoked.key
    try await database.write { db in
      for event in ["INSERT", "UPDATE"] {
        try db.execute(
          sql: """
            CREATE TRIGGER refuse_revocation_\(event.lowercased()) BEFORE \(event) ON setting
            WHEN NEW.key = '\(revokedKey)' BEGIN SELECT RAISE(ABORT, 'refused'); END
            """)
      }
    }

    let runtime = Self.runtime(
      settings: settings, clock: clock,
      transport: Self.transport(body: ["token": token, "revoked": true]))
    #expect(await runtime.status().tier == .pro)
    #expect(await runtime.refresh() == .revoked)
    #expect(await LicenseStore(settings: settings).load(verifier: Self.verify).isRevoked == false)
    #expect(await runtime.status() == .revoked)
    // A reload from disk, which is what a settings change triggers, does not undo it.
    #expect(await runtime.reload() == .revoked)

    // A different key is not refused for the old one's revocation.
    try await settings.set(Settings.licenseKey, to: "LK-456")
    #expect(await runtime.reload() != .revoked)
  }

  /// A key the issuer refuses and an issuer that cannot answer are different failures: one
  /// is about the key, the other about the moment. Folded together, a mistyped key was told
  /// to check the internet connection.
  @Test(
    "A refused key and an unavailable issuer are told apart",
    arguments: [
      (404, true), (403, true), (400, true), (500, false), (503, false), (429, false), (408, false),
    ])
  func refusalIsNotAnOutage(status: Int, isRefusal: Bool) async throws {
    let settings = try await Self.store()
    try await settings.set(Settings.licenseKey, to: "LK-123")
    let runtime = Self.runtime(
      settings: settings, clock: ManualClock(Self.start),
      transport: Self.transport(status: status, body: ["reason": "unknown key"]))

    switch await runtime.refresh() {
    case .refused: #expect(isRefusal, "HTTP \(status) is the issuer failing, not refusing")
    case .failed: #expect(!isRefusal, "HTTP \(status) is the issuer refusing this key")
    case let other: Issue.record("expected a refusal or a failure, got \(other)")
    }
  }

  @Test("A failed refresh keeps the token already in hand")
  func failedRefreshKeepsEntitlement() async throws {
    let settings = try await Self.store()
    try await settings.set(Settings.licenseKey, to: "LK-123")
    let clock = ManualClock(Self.start)

    let good = try Self.mint(expires: Self.start.addingTimeInterval(7 * 86_400))
    let working = Self.runtime(
      settings: settings, clock: clock, transport: Self.transport(body: ["token": good]))
    #expect(await working.refresh() == .refreshed(.pro))

    // The issuer goes away. Two days pass: well inside the window.
    let broken = Self.runtime(
      settings: settings, clock: clock,
      transport: { _ in throw URLError(.notConnectedToInternet) })
    clock.advance(by: 2 * 86_400)

    guard case .failed = await broken.refresh() else {
      Issue.record("expected a transport failure")
      return
    }
    #expect(await broken.status().tier == .pro, "the entitlement must survive a failed refresh")
    #expect(await settings.get(Settings.licenseToken).isEmpty == false)

    // Past the window, the same held token stops being enough.
    clock.advance(by: 6 * 86_400)
    #expect(await broken.reload().refusal(forRequired: .pro)?.reason == "validation_unavailable")
  }

  /// A token the issuer answers with that does not verify (signed by another key here)
  /// used to be stored before it was checked: it replaced the good one, reset the
  /// last-check clock so no warning fired, and refused the server at once.
  @Test("A token that does not verify is a failed refresh, and replaces nothing")
  func unverifiableTokenIsNotStored() async throws {
    let settings = try await Self.store()
    try await settings.set(Settings.licenseKey, to: "LK-123")
    let clock = ManualClock(Self.start)

    let good = try Self.mint(expires: Self.start.addingTimeInterval(7 * 86_400))
    let working = Self.runtime(
      settings: settings, clock: clock, transport: Self.transport(body: ["token": good]))
    #expect(await working.refresh() == .refreshed(.pro))
    let checkedAt = await settings.get(Settings.licenseLastCheck)

    // Same shape, wrong signature.
    let parts = good.split(separator: ".")
    let forged =
      "\(parts[0]).\(parts[1])."
      + Base64URL.encode(try Curve25519.Signing.PrivateKey().signature(for: Data("x".utf8)))
    clock.advance(by: 86_400)
    let answering = Self.runtime(
      settings: settings, clock: clock, transport: Self.transport(body: ["token": forged]))

    guard case .failed = await answering.refresh() else {
      Issue.record("an unverifiable token must be a failed refresh")
      return
    }
    #expect(await settings.get(Settings.licenseToken) == good, "the good token was replaced")
    #expect(
      await settings.get(Settings.licenseLastCheck) == checkedAt,
      "a failed refresh must not reset the clock the warnings run on")
    #expect(await answering.status().tier == .pro, "the entitlement in hand must survive")
  }

  // MARK: - Auditing

  /// The runtime is the only thing that knows these, so it is the one that says. What a
  /// record keeps is the bridge's business; what is asserted here is that every fact reaches
  /// the auditor once, in the order it happened, and that nothing is reported twice.
  @Test("Every move, exchange, revocation and removal reaches the auditor once")
  func reportsToTheAuditor() async throws {
    let settings = try await Self.store()
    let clock = ManualClock(Self.start)
    let auditor = CapturingAuditor<LicenseAuditEvent>()

    // Priming to "no licence" is not news: every unlicensed server would say it on each start.
    let unlicensed = Self.runtime(
      settings: settings, clock: clock, transport: { _ in throw CancellationError() },
      auditor: auditor)
    #expect(await unlicensed.status() == .none)
    await unlicensed.reload()
    #expect(auditor.recorded.isEmpty)

    // A key with nothing behind it moves the status; the second reload says the same and is
    // silent.
    try await settings.set(Settings.licenseKey, to: "LK-123")
    await unlicensed.reload()
    await unlicensed.reload()
    // Spelled in full: a bare `.none` in an optional position is `Optional.none`.
    #expect(
      auditor.recorded == [
        .statusChanged(previous: LicenseStatus.none, current: .unverifiable(since: nil))
      ])
    auditor.clear()

    // A successful exchange: the move, then the token the issuer answered with.
    let ends = Self.start.addingTimeInterval(30 * 86_400)
    let token = try Self.mint(
      expires: Self.start.addingTimeInterval(7 * 86_400), subscriptionEnds: ends)
    let working = Self.runtime(
      settings: settings, clock: clock, transport: Self.transport(body: ["token": token]),
      auditor: auditor)
    // Primed first, as a served runtime always is (the service reloads on start, the gate
    // reads before any exchange), so the move has a previous status to name.
    _ = await working.status()
    auditor.clear()
    #expect(await working.refresh() == .refreshed(.pro))
    #expect(auditor.recorded.count == 2)
    guard case .statusChanged(let previous, let current)? = auditor.recorded.first else {
      Issue.record("expected the status move first, got \(auditor.recorded)")
      return
    }
    #expect(previous == .unverifiable(since: nil))
    #expect(current.tier == .pro)
    guard case .refreshed(let received)? = auditor.recorded.last else {
      Issue.record("expected the token second, got \(auditor.recorded)")
      return
    }
    #expect(received.subscriptionEndsAt == ends)
    auditor.clear()

    // A failed exchange is reported, and the status did not move so nothing else is.
    let broken = Self.runtime(
      settings: settings, clock: clock,
      transport: { _ in throw URLError(.notConnectedToInternet) }, auditor: auditor)
    _ = await broken.status()
    auditor.clear()
    guard case .failed = await broken.refresh() else {
      Issue.record("expected a transport failure")
      return
    }
    #expect(auditor.recorded.count == 1)
    guard case .refreshFailed(let reason)? = auditor.recorded.first else {
      Issue.record("expected the failure, got \(auditor.recorded)")
      return
    }
    // A sentence an operator can read in the audit log, not the enum case it came from.
    #expect(reason.hasPrefix("The license service could not be reached: "))
    #expect(!reason.contains("transport("))
    auditor.clear()

    // Revocation: the move and the issuer's word, once. The daily tick repeating the
    // issuer's answer adds nothing.
    let revoking = Self.runtime(
      settings: settings, clock: clock,
      transport: Self.transport(body: ["token": token, "revoked": true]), auditor: auditor)
    _ = await revoking.status()
    auditor.clear()
    #expect(await revoking.refresh() == .revoked)
    #expect(
      auditor.recorded == [
        .statusChanged(previous: .active(try Self.verify(token)), current: .revoked), .revoked,
      ])
    #expect(await revoking.refresh() == .revoked)
    #expect(auditor.recorded.count == 2, "a repeated revocation is not a second record")
    auditor.clear()

    // Removal: the move to nothing, then the removal naming what was held.
    try await revoking.clear()
    #expect(
      auditor.recorded == [
        .statusChanged(previous: .revoked, current: LicenseStatus.none),
        .removed(previous: .revoked),
      ])
  }

  @Test("A rejecting issuer is a failure, not a revocation")
  func rejectionIsNotRevocation() async throws {
    let settings = try await Self.store()
    try await settings.set(Settings.licenseKey, to: "LK-123")
    let runtime = Self.runtime(
      settings: settings, clock: ManualClock(Self.start),
      transport: Self.transport(status: 500, body: ["reason": "boom"]))

    guard case .failed = await runtime.refresh() else {
      Issue.record("expected a failure")
      return
    }
    #expect(await settings.get(Settings.licenseRevoked) == false)
  }

  @Test("A warning fires once per threshold, not once per attempt")
  func warnsOnce() async throws {
    let settings = try await Self.store()
    try await settings.set(Settings.licenseKey, to: "LK-123")
    let clock = ManualClock(Self.start)
    let token = try Self.mint(expires: Self.start.addingTimeInterval(7 * 86_400))

    let runtime = Self.runtime(
      settings: settings, clock: clock, transport: Self.transport(body: ["token": token]))
    _ = await runtime.refresh()

    clock.advance(by: 3 * 86_400)
    #expect(await runtime.pendingWarning() == LicenseWindows.warningThresholds[0])
    #expect(await runtime.pendingWarning() == nil, "the same threshold must not warn twice")

    clock.advance(by: 2 * 86_400)
    #expect(await runtime.pendingWarning() == LicenseWindows.warningThresholds[1])
  }

  @Test("A token minted for another Mac is refused")
  func machineBinding() async throws {
    let settings = try await Self.store()
    try await settings.set(Settings.licenseKey, to: "LK-123")
    let token = try Self.mint(
      machine: MachineFingerprint.of(seed: "a-different-mac"),
      expires: Self.start.addingTimeInterval(7 * 86_400))
    let runtime = Self.runtime(
      settings: settings, clock: ManualClock(Self.start),
      transport: Self.transport(body: ["token": token]))

    _ = await runtime.refresh()
    #expect(await runtime.status().refusal(forRequired: .pro)?.reason == "machine_mismatch")
  }

  @Test("The fingerprint is stable, and is not the seed")
  func fingerprint() {
    let seed = "ABC-123"
    #expect(MachineFingerprint.of(seed: seed) == MachineFingerprint.of(seed: seed))
    #expect(MachineFingerprint.of(seed: seed) != MachineFingerprint.of(seed: "ABC-124"))
    #expect(!MachineFingerprint.of(seed: seed).contains(seed))
    #expect(MachineFingerprint.of(seed: seed).count == 64)
  }
}

extension LicenseRuntimeTests {

  /// THE SHAPE THE WORKER ACTUALLY SENDS when a license is disabled.
  ///
  /// `Tools/license-worker/worker.js` answers `{"token": null, "revoked": true}` for a refund,
  /// a chargeback or a manual revocation: there is no token to mint, because there is no
  /// entitlement to describe. The earlier test passed a token ALONGSIDE `revoked`, which is a
  /// shape nothing produces — so it proved the branch worked and not that the branch is
  /// reachable.
  @Test("A revocation with no token is a revocation, not a malformed response")
  func revokedWithoutToken() async throws {
    let settings = try await Self.store()
    try await settings.set(Settings.licenseKey, to: "LK-123")
    let runtime = Self.runtime(
      settings: settings, clock: ManualClock(Self.start),
      transport: Self.transport(body: ["token": NSNull(), "revoked": true]))

    #expect(await runtime.refresh() == .revoked)
    #expect(await settings.get(Settings.licenseRevoked))
    #expect(await runtime.status().refusal(forRequired: .pro)?.reason == "license_revoked")
  }

  /// And the field being absent entirely, which is the same statement.
  @Test("A revocation with the token field omitted behaves identically")
  func revokedWithTokenOmitted() async throws {
    let settings = try await Self.store()
    try await settings.set(Settings.licenseKey, to: "LK-123")
    let runtime = Self.runtime(
      settings: settings, clock: ManualClock(Self.start),
      transport: Self.transport(body: ["revoked": true]))

    #expect(await runtime.refresh() == .revoked)
  }

  /// But a success with no token is still malformed: that is a broken issuer, not a
  /// revocation, and treating it as one would silently disable a paying customer.
  @Test("A non-revoked response with no token is still a failure")
  func missingTokenIsStillMalformed() async throws {
    let settings = try await Self.store()
    try await settings.set(Settings.licenseKey, to: "LK-123")
    let runtime = Self.runtime(
      settings: settings, clock: ManualClock(Self.start),
      transport: Self.transport(body: ["revoked": false]))

    guard case .failed = await runtime.refresh() else {
      Issue.record("a missing token on a non-revoked response must not be treated as success")
      return
    }
    #expect(await settings.get(Settings.licenseRevoked) == false)
  }
}

extension LicenseRuntimeTests {

  /// The end-to-end version: a key is entered, the issuer is unreachable, and the server must
  /// say "could not confirm" rather than "no subscription".
  @Test("A key entered while the issuer is unreachable reports as unconfirmed")
  func unreachableIssuerWithAKey() async throws {
    let settings = try await Self.store()
    try await settings.set(Settings.licenseKey, to: "LK-123")
    let runtime = Self.runtime(
      settings: settings, clock: ManualClock(Self.start),
      transport: { _ in throw URLError(.cannotFindHost) })

    guard case .failed = await runtime.refresh() else {
      Issue.record("expected a transport failure")
      return
    }
    #expect(await runtime.status().refusal(forRequired: .pro)?.reason == "validation_unavailable")
  }
}

/// Only this target tests the runtime's seam, so the conformance lives beside it rather than
/// making BBTestSupport depend on BBLicensing.
extension CapturingAuditor: LicenseAuditing where Event == LicenseAuditEvent {}
