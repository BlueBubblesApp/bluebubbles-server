//  DeviceRegistry
//  Enrolled devices: minting, rotating, revoking.
//
//  What this buys over the shared password: **revocation is deleting one row.** Today a
//  compromised device can only be locked out by changing the password for every device the
//  user owns, because there is no identity to revoke.
//
//  Dormant by default — nothing here is constructed under `auth_mode = password`, and no
//  table is created. See `docs/AUTH.md`.

import Foundation
import Logging

/// Storage for enrolled devices, behind a protocol so the registry can be exercised without
/// a database and so persistence can move later without touching the policy above it.
public protocol DeviceStoring: Sendable {
  func device(clientId: String) async throws -> EnrolledDevice?
  func allDevices() async throws -> [EnrolledDevice]
  func save(_ device: EnrolledDevice) async throws
  func delete(id: DeviceID) async throws
}

/// In-memory storage. Used by tests, and by a server that has token auth on but has not yet
/// been given a persistent store.
public actor InMemoryDeviceStore: DeviceStoring {

  private var devices: [String: EnrolledDevice] = [:]

  public init() {}

  public func device(clientId: String) async throws -> EnrolledDevice? {
    devices[clientId]
  }

  public func allDevices() async throws -> [EnrolledDevice] {
    devices.values.sorted { $0.enrolledAt < $1.enrolledAt }
  }

  public func save(_ device: EnrolledDevice) async throws {
    devices[device.clientId] = device
  }

  public func delete(id: DeviceID) async throws {
    devices = devices.filter { $0.value.id != id }
  }
}

// MARK: - The registry

public actor DeviceRegistry {

  private let store: any DeviceStoring
  private let logger: Logger
  /// Outstanding enrollment codes, keyed by their normalized value. In memory on purpose:
  /// they live five minutes, and a code that survives a server restart is a code that
  /// outlives the user's attention.
  private var enrollmentCodes: [String: EnrollmentCode] = [:]

  public init(
    store: any DeviceStoring = InMemoryDeviceStore(),
    logger: Logger = Logger(label: "bluebubbles.auth.devices")
  ) {
    self.store = store
    self.logger = logger
  }

  // MARK: Enrollment codes

  /// Mints a code for the server UI to display.
  @discardableResult
  public func issueEnrollmentCode(now: Date = Date()) -> EnrollmentCode {
    purgeExpiredCodes(now: now)
    let code = EnrollmentCode.generate(now: now)
    enrollmentCodes[code.value] = code
    return code
  }

  /// Consumes a code. Single use: valid once, then gone whether or not enrollment succeeds
  /// afterwards — a code that could be retried is a code that can be brute-forced.
  func consumeEnrollmentCode(_ candidate: String, now: Date = Date()) throws {
    // Deliberately NOT purged first. A code that has expired is still a code we issued,
    // and saying so lets the user ask for another instead of wondering whether they
    // mistyped it. Purging first would collapse both cases into "invalid". Nothing is
    // leaked either way: the caller already holds a code we minted.
    let normalized = EnrollmentCode.normalize(candidate)

    // Scanned rather than looked up by key, so the comparison stays constant-time. A
    // dictionary lookup on the candidate would compare with `==` and leak the prefix.
    var matched: EnrollmentCode?
    for code in enrollmentCodes.values where code.matches(normalized) {
      matched = code
    }

    guard let matched else {
      // Bound the table here instead, since this is the path an attacker exercises.
      purgeExpiredCodes(now: now)
      throw EnrollmentError.invalidEnrollmentCode
    }
    // Consumed whether or not it turned out to be valid — a code that could be retried
    // is a code that can be brute-forced.
    enrollmentCodes.removeValue(forKey: matched.value)
    guard matched.isValid(at: now) else { throw EnrollmentError.enrollmentCodeExpired }
  }

  private func purgeExpiredCodes(now: Date) {
    enrollmentCodes = enrollmentCodes.filter { $0.value.isValid(at: now) }
  }

  public var outstandingCodeCount: Int { enrollmentCodes.count }

  // MARK: Enrollment

  /// Mints credentials for a device.
  ///
  /// The secret is returned here and never again — it is stored hashed, so the server
  /// itself cannot recover it. A client that loses it re-enrolls.
  public func enroll(
    name: String,
    platform: String,
    scopes: Set<Scope> = Scope.all,
    publicKey: Data? = nil,
    supportedCodecs: [String] = [],
    now: Date = Date()
  ) async throws -> (credentials: ClientCredentials, device: EnrolledDevice) {
    let clientId = ClientSecret.generateIdentifier()
    let secret = ClientSecret.generate()

    let device = EnrolledDevice(
      id: DeviceID(UUID().uuidString),
      clientId: clientId,
      secret: try SecretHash.make(secret),
      name: name,
      platform: platform,
      // Everything by default, so enabling token auth breaks nothing. Read-only
      // clients become possible; they are not imposed.
      scopes: scopes,
      publicKey: publicKey,
      supportedCodecs: supportedCodecs,
      enrolledAt: now
    )
    try await store.save(device)

    logger.info(
      "Enrolled a device",
      metadata: [
        "name": .string(name),
        "platform": .string(platform),
      ])
    return (ClientCredentials(clientId: clientId, clientSecret: secret), device)
  }

  // MARK: Authentication

  /// Verifies a `client_credentials` grant.
  ///
  /// A revoked device is rejected distinctly from an unknown one *internally* — the caller
  /// collapses both before answering, since telling an attacker which client ids exist is
  /// free information.
  public func authenticate(
    clientId: String,
    clientSecret: String,
    now: Date = Date()
  ) async throws -> EnrolledDevice {
    guard let device = try await store.device(clientId: clientId) else {
      // Still does the hashing work on a dummy value, so a request for an unknown
      // client id does not return measurably faster than one for a known id with a
      // wrong secret. Otherwise timing enumerates valid client ids.
      _ = SecretHash.dummy.verify(clientSecret)
      throw EnrollmentError.invalidClientCredentials
    }
    guard !device.isRevoked else { throw EnrollmentError.deviceRevoked }
    guard device.secret.verify(clientSecret) else {
      throw EnrollmentError.invalidClientCredentials
    }

    var seen = device
    seen.lastSeenAt = now
    try await store.save(seen)
    return seen
  }

  /// Records that a device used a token, for the Devices screen's last-seen column.
  public func noteActivity(clientId: String, now: Date = Date()) async {
    guard var device = try? await store.device(clientId: clientId) else { return }
    device.lastSeenAt = now
    try? await store.save(device)
  }

  // MARK: Rotation and revocation

  /// Issues a new secret and invalidates the old one.
  ///
  /// Authenticated with the CURRENT secret, so a suspected leak does not require
  /// re-enrolling the device — which on a phone means the user finding the server UI again.
  public func rotateSecret(
    clientId: String,
    currentSecret: String,
    now: Date = Date()
  ) async throws -> ClientCredentials {
    var device = try await authenticate(
      clientId: clientId, clientSecret: currentSecret, now: now
    )

    let replacement = ClientSecret.generate()
    device.secret = try SecretHash.make(replacement)
    try await store.save(device)

    logger.info("Rotated a device secret", metadata: ["device": .string(device.name)])
    return ClientCredentials(clientId: clientId, clientSecret: replacement)
  }

  /// Revokes a device.
  ///
  /// Marked rather than deleted, so the Devices screen can show that a device WAS revoked
  /// rather than having it silently vanish — a user who revokes the wrong phone should be
  /// able to see what they did.
  public func revoke(id: DeviceID) async throws {
    guard var device = try await allDevices().first(where: { $0.id == id }) else {
      throw EnrollmentError.unknownDevice
    }
    device.isRevoked = true
    try await store.save(device)
    logger.info("Revoked a device", metadata: ["device": .string(device.name)])
  }

  /// Removes a device entirely.
  public func forget(id: DeviceID) async throws {
    try await store.delete(id: id)
  }

  public func allDevices() async throws -> [EnrolledDevice] {
    try await store.allDevices()
  }

  public func device(clientId: String) async throws -> EnrolledDevice? {
    try await store.device(clientId: clientId)
  }

  /// Writes a modified device back.
  ///
  /// Narrow on purpose: scope changes are a real operation the Devices screen will need,
  /// but they must go through the registry rather than letting callers reach the store.
  public func update(_ device: EnrolledDevice) async throws {
    try await store.save(device)
  }
}

extension SecretHash {
  /// A fixed hash to verify against when no device matched.
  ///
  /// Its only job is to make the work comparable — see the note in `authenticate`. Computed
  /// once because computing it per call would itself be a timing signal.
  static let dummy: SecretHash = {
    (try? SecretHash.make("bluebubbles-timing-equaliser"))
      ?? SecretHash(salt: Data(repeating: 0, count: 16), hash: Data(repeating: 0, count: 32))
  }()
}
