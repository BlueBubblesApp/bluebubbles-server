//  ServiceAccount
//  Google service-account credentials, and where they are kept.
//
//  Vulnerability #1 from the 2023 report is that today these live unencrypted in Application
//  Support (`fcmDir/server.json`), where any non-privileged local process can read them. With
//  them, an attacker rewrites `serverUrl` and redirects every client through a proxy of their
//  choosing — capturing plaintext messages *and* the server password.
//
//  So the credential never lands on disk here. It is parsed, validated, and handed to the
//  Keychain; the JSON the user imported is deleted afterwards. See `.claude/docs/decisions.md`.

import BBCore
import BBSettings
import Foundation

/// A Firebase Admin service-account key, as downloaded from the Google Cloud console.
///
/// Only the fields actually used are modelled. `type` is checked because the console will
/// happily hand out an OAuth *client* JSON that looks similar and fails much later.
public struct ServiceAccount: Codable, Sendable, Equatable {

  public let type: String
  public let projectId: String
  public let privateKeyId: String
  public let privateKey: String
  public let clientEmail: String
  public let tokenURI: String

  enum CodingKeys: String, CodingKey {
    case type
    case projectId = "project_id"
    case privateKeyId = "private_key_id"
    case privateKey = "private_key"
    case clientEmail = "client_email"
    case tokenURI = "token_uri"
  }

  public init(
    type: String = "service_account",
    projectId: String,
    privateKeyId: String,
    privateKey: String,
    clientEmail: String,
    tokenURI: String = "https://oauth2.googleapis.com/token"
  ) {
    self.type = type
    self.projectId = projectId
    self.privateKeyId = privateKeyId
    self.privateKey = privateKey
    self.clientEmail = clientEmail
    self.tokenURI = tokenURI
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decodeIfPresent(String.self, forKey: .type) ?? "service_account"
    projectId = try container.decode(String.self, forKey: .projectId)
    privateKeyId = try container.decodeIfPresent(String.self, forKey: .privateKeyId) ?? ""
    privateKey = try container.decode(String.self, forKey: .privateKey)
    clientEmail = try container.decode(String.self, forKey: .clientEmail)
    tokenURI =
      try container.decodeIfPresent(String.self, forKey: .tokenURI)
      ?? "https://oauth2.googleapis.com/token"
  }

  /// Parses and sanity-checks a downloaded key file.
  ///
  /// The checks are worth doing at import time rather than at first send: a wrong file
  /// produces an authentication failure hours later, with nothing pointing at the cause.
  public static func parse(_ data: Data) throws -> ServiceAccount {
    let account: ServiceAccount
    do {
      account = try JSONDecoder().decode(ServiceAccount.self, from: data)
    } catch {
      throw PushConfigurationError.malformedServiceAccount(reason: String(describing: error))
    }

    guard account.type == "service_account" else {
      throw PushConfigurationError.notAServiceAccount(found: account.type)
    }
    guard account.privateKey.contains("PRIVATE KEY") else {
      throw PushConfigurationError.malformedServiceAccount(
        reason: "private_key does not look like a PEM key"
      )
    }
    guard !account.projectId.isEmpty, !account.clientEmail.isEmpty else {
      throw PushConfigurationError.malformedServiceAccount(
        reason: "project_id and client_email are both required"
      )
    }
    return account
  }
}

/// The client config (`google-services.json`), which carries the project number.
///
/// **A PROJECTION, not the document.** Only the three fields the server itself reasons about
/// are modelled here. The file also carries `client[]` — the Android API key and the
/// `mobilesdk_app_id` — which this server never reads but which clients cannot construct
/// `FirebaseOptions` without.
///
/// So this type is never what gets STORED. `PushCredentialStore` keeps the bytes the user
/// imported and decodes this projection out of them on demand. Storing the projection instead
/// is what broke `GET /api/v1/fcm/client`: the re-encoded document contained `project_info`
/// and nothing else, and every Android client that fetched its configuration from the server
/// got a file with no API key in it.
public struct FirebaseClientConfig: Codable, Sendable, Equatable {
  public let projectNumber: String
  public let projectId: String
  /// Present only when the project uses the Realtime Database rather than Firestore.
  public let firebaseURL: String?

  public init(projectNumber: String, projectId: String, firebaseURL: String? = nil) {
    self.projectNumber = projectNumber
    self.projectId = projectId
    self.firebaseURL = firebaseURL
  }

  public init(from decoder: any Decoder) throws {
    // Shaped as `{"project_info": {...}}`, so it is reached through a nested container
    // rather than flattened — the file is Google's, and reshaping it at import would
    // mean re-deriving it whenever they change it.
    let root = try decoder.container(keyedBy: RootKeys.self)
    let info = try root.nestedContainer(keyedBy: InfoKeys.self, forKey: .projectInfo)
    projectNumber = try info.decode(String.self, forKey: .projectNumber)
    projectId = try info.decode(String.self, forKey: .projectId)
    firebaseURL = try info.decodeIfPresent(String.self, forKey: .firebaseURL)
  }

  public func encode(to encoder: any Encoder) throws {
    var root = encoder.container(keyedBy: RootKeys.self)
    var info = root.nestedContainer(keyedBy: InfoKeys.self, forKey: .projectInfo)
    try info.encode(projectNumber, forKey: .projectNumber)
    try info.encode(projectId, forKey: .projectId)
    try info.encodeIfPresent(firebaseURL, forKey: .firebaseURL)
  }

  private enum RootKeys: String, CodingKey { case projectInfo = "project_info" }
  private enum InfoKeys: String, CodingKey {
    case projectNumber = "project_number"
    case projectId = "project_id"
    case firebaseURL = "firebase_url"
  }

  /// Which database the project uses.
  ///
  /// Derived from the presence of `firebase_url`, which is how the reference decides
  /// too — a project has one or the other, never both.
  public var databaseKind: FirebaseDatabaseKind {
    (firebaseURL?.isEmpty == false) ? .realtime : .firestore
  }

  /// Validates a downloaded `google-services.json` and returns the projection.
  ///
  /// `client[]` is required even though nothing here reads it, for the same reason
  /// `ServiceAccount.parse` checks `type`: a file that is missing it parses fine, stores
  /// fine, and then fails on the client days later with nothing pointing back at this
  /// moment.
  ///
  /// This is STRICTER than the reference, deliberately, and an earlier version of this
  /// comment claimed the opposite by citing an `isValidClientConfig` that does not exist.
  /// The reference does not validate this file at all: `FileSystem.getFCMClient()`
  /// (`server/fileSystem/index.ts:416`) checks that the path exists and the contents are
  /// non-empty, then `JSON.parse`s and returns whatever it got. That absence is the reason
  /// the late failure is worth catching here rather than an argument for matching it —
  /// nothing about the client contract depends on our accepting a file the reference
  /// would also have accepted.
  public static func parse(_ data: Data) throws -> FirebaseClientConfig {
    guard let config = try? JSONDecoder().decode(FirebaseClientConfig.self, from: data) else {
      throw PushConfigurationError.malformedClientConfig(
        reason: "the file has no `project_info` section"
      )
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let clients = object["client"] as? [Any], !clients.isEmpty
    else {
      throw PushConfigurationError.malformedClientConfig(
        reason: "the file has no registered app in its `client` list. Register an "
          + "Android app in Project Settings and download it again."
      )
    }
    return config
  }
}

public enum FirebaseDatabaseKind: String, Sendable, Equatable, CaseIterable {
  case firestore
  case realtime
}

public enum PushConfigurationError: BBError, Equatable {
  case notAServiceAccount(found: String)
  case malformedServiceAccount(reason: String)
  case malformedClientConfig(reason: String)
  case notConfigured
}

// MARK: - Storage

/// Loads and stores push credentials in the Keychain.
///
/// The whole point of this type is that there is no filesystem path involved. A caller that
/// wants the credential asks here; nothing else ever holds it.
public actor PushCredentialStore {

  /// Keychain accounts. Distinct entries so the client config can be replaced without
  /// touching the private key.
  static let serviceAccountKey = "fcm.service_account"
  static let clientConfigKey = "fcm.client_config"

  private let secrets: any SecretStore

  public init(secrets: any SecretStore) {
    self.secrets = secrets
  }

  public func serviceAccount() throws -> ServiceAccount? {
    guard let raw = try rawServiceAccount() else { return nil }
    return try? JSONDecoder().decode(ServiceAccount.self, from: raw)
  }

  public func clientConfig() throws -> FirebaseClientConfig? {
    guard let raw = try rawClientConfig() else { return nil }
    return try? JSONDecoder().decode(FirebaseClientConfig.self, from: raw)
  }

  /// The service-account document exactly as it was imported.
  ///
  /// Nothing serves this over HTTP and nothing should — it holds the private key. It exists
  /// so the stored copy stays byte-faithful to what Google issued, which keeps fields the
  /// projection does not model (`client_id`, `auth_uri`, `universe_domain`) available to a
  /// future reader rather than silently dropping them at import.
  public func rawServiceAccount() throws -> Data? {
    guard let raw = try secrets.get(Self.serviceAccountKey), !raw.isEmpty else { return nil }
    return Data(raw.utf8)
  }

  /// The `google-services.json` exactly as it was imported.
  ///
  /// This is what `GET /api/v1/fcm/client` serves. It MUST be the whole document: clients
  /// read `client[].api_key[].current_key` and `client[].client_info.mobilesdk_app_id` out
  /// of it, neither of which the projection carries.
  public func rawClientConfig() throws -> Data? {
    guard let raw = try secrets.get(Self.clientConfigKey), !raw.isEmpty else { return nil }
    return Data(raw.utf8)
  }

  /// Imports a downloaded key file.
  ///
  /// The document is validated and then stored VERBATIM. Storing a re-encoded projection
  /// instead is what silently truncated the client configuration, and the same mistake was
  /// available here.
  ///
  /// - Parameter deletingFileAt: The path the user pointed at. Removed once the credential
  ///   is safely in the Keychain, because leaving it in Downloads recreates the exact
  ///   exposure this type exists to close.
  @discardableResult
  public func importServiceAccount(
    _ data: Data,
    deletingFileAt path: String? = nil
  ) throws -> ServiceAccount {
    let account = try ServiceAccount.parse(data)
    try secrets.set(Self.serviceAccountKey, value: String(decoding: data, as: UTF8.self))
    if let path {
      try? FileManager.default.removeItem(atPath: path)
    }
    return account
  }

  @discardableResult
  public func importClientConfig(
    _ data: Data,
    deletingFileAt path: String? = nil
  ) throws -> FirebaseClientConfig {
    let config = try FirebaseClientConfig.parse(data)
    try secrets.set(Self.clientConfigKey, value: String(decoding: data, as: UTF8.self))
    if let path {
      try? FileManager.default.removeItem(atPath: path)
    }
    return config
  }

  /// Removes both credentials.
  ///
  /// Each delete is independent, and the first error is rethrown only after BOTH have been
  /// attempted. Sequential `try`s meant a failure on the first entry skipped the second
  /// entirely, leaving the server half-credentialled with no indication of which half
  /// survived — the worst outcome for an operation whose entire purpose is to leave nothing
  /// behind.
  public func clear() throws {
    var failure: (any Error)?
    do { try secrets.delete(Self.serviceAccountKey) } catch { failure = error }
    do { try secrets.delete(Self.clientConfigKey) } catch { failure = failure ?? error }
    if let failure { throw failure }
  }

  /// The Firebase project the stored credentials belong to.
  ///
  /// Read before an import so a project SWAP can be detected. Device tokens are minted by
  /// one project and are meaningless to another, so credentials for a different project
  /// have to take the registered devices with them — the reference server clears them in
  /// both its import path and its provisioning path, and skipping it leaves a device list
  /// that fails every send with no error a user would ever see.
  public func currentProjectId() -> String? {
    ((try? serviceAccount()) ?? nil)?.projectId
  }

  /// Whether importing `data` would move this server to a different Firebase project.
  ///
  /// False when nothing is configured yet: arriving at a project from nowhere is setup,
  /// not a swap, and there are no stale tokens to clear.
  public func wouldChangeProject(_ data: Data) -> Bool {
    guard let current = currentProjectId(),
      let incoming = try? ServiceAccount.parse(data)
    else { return false }
    return current != incoming.projectId
  }

  /// Whether push is configured at all.
  ///
  /// Push is optional: with no credentials the services are never registered, the server
  /// starts clean, and nothing is logged as a defect. This is what that decision reads.
  public func isConfigured() -> Bool {
    ((try? serviceAccount()) ?? nil) != nil
  }

  /// Whether the service account specifically is stored. Used by the migration, which
  /// decides each file on its own.
  public func hasServiceAccount() -> Bool {
    ((try? secrets.get(Self.serviceAccountKey)) ?? nil)?.isEmpty == false
  }

  /// Whether the client config specifically is stored.
  public func hasClientConfig() -> Bool {
    ((try? secrets.get(Self.clientConfigKey)) ?? nil)?.isEmpty == false
  }

  /// Whether push can start.
  ///
  /// The same question as `isConfigured`, and that is the point. It used to be
  /// `isConfigured() || hasLegacyCredentials()`, because the migration ran inside
  /// `PushService.start()` and a Keychain-only gate would have declined on exactly the
  /// installs that had plaintext waiting — leaving it readable forever. Adoption is now a
  /// step the user takes before the server starts, so by the time this is asked the
  /// credentials are either in the Keychain or genuinely absent.
  ///
  /// Kept as a distinct name rather than folded into the caller so the reason survives:
  /// a future edit that reintroduces "…or there are files on disk" would reintroduce a
  /// service that starts, wires a full delivery stack, and then reports zero outcomes for
  /// every notification because `sender` was never built.
  public func isConfigurable() -> Bool { isConfigured() }
}

// MARK: - Migration

public enum PushCredentialMigration {

  /// Where the reference keeps these, in the clear.
  ///
  /// `in:` exists for tests, and for a reason worth stating: with the real path baked in,
  /// anything asserting about "no credentials present" asserts something DIFFERENT on a
  /// machine that happens to have an Electron install — which is the state a developer's
  /// own Mac is most likely to be in. Injecting the directory is what makes those tests
  /// deterministic. Same shape as `CertificateStore.init(directory:)`.
  public static func legacyPaths(
    in base: URL = ApplicationSupport.directory
  ) -> (serviceAccount: String, clientConfig: String) {
    let firebase = base.appendingPathComponent("FCM", isDirectory: true)
    return (
      firebase.appendingPathComponent("server.json").path,
      firebase.appendingPathComponent("client.json").path
    )
  }

  /// Whether an unmigrated service account is still sitting in Application Support.
  public static func hasLegacyCredentials(in base: URL = ApplicationSupport.directory) -> Bool {
    FileManager.default.fileExists(atPath: legacyPaths(in: base).serviceAccount)
  }

  /// Moves credentials out of Application Support and into the Keychain.
  ///
  /// Deleting the plaintext afterwards is the point — a migration that copies without
  /// removing leaves the vulnerability exactly where it was, plus a second copy.
  ///
  /// **Each file is decided on its own.** The guard used to be a single
  /// `!store.isConfigured()` over both, which had a hole: `server.json` imports and is
  /// deleted, `client.json` then fails, and `isConfigured()` is now true — so the next run
  /// returns early and `client.json` is never migrated and never deleted. Plaintext left
  /// forever, and `GET /api/v1/fcm/client` serving nothing. Now the service account is
  /// skipped only if the service account is already stored, and likewise the client config,
  /// so a half-done move finishes on the next attempt.
  @discardableResult
  public static func migrateIfNeeded(
    into store: PushCredentialStore,
    from base: URL = ApplicationSupport.directory
  ) async throws -> Bool {
    let paths = legacyPaths(in: base)
    var migrated = false

    if await !store.hasServiceAccount(),
      let data = FileManager.default.contents(atPath: paths.serviceAccount)
    {
      _ = try await store.importServiceAccount(data, deletingFileAt: paths.serviceAccount)
      migrated = true
    }
    if await !store.hasClientConfig(),
      let data = FileManager.default.contents(atPath: paths.clientConfig)
    {
      // Still tolerant: a malformed client config must not strand a service account that
      // moved successfully. The next run retries it, because the guard above is per file.
      if (try? await store.importClientConfig(data, deletingFileAt: paths.clientConfig)) != nil {
        migrated = true
      }
    }
    return migrated
  }
}

extension PushConfigurationError {
  public var code: String {
    switch self {
    case .notAServiceAccount: "push.not_a_service_account"
    case .malformedServiceAccount: "push.malformed_service_account"
    case .malformedClientConfig: "push.malformed_client_config"
    case .notConfigured: "push.not_configured"
    }
  }

  public var domain: String { "Push" }

  /// The user uploaded a file and it was wrong; nothing else would tell them.
  /// `notConfigured` is a normal state on a server that never set push up.
  public var isUserFacing: Bool {
    if case .notConfigured = self { return false }
    return true
  }

  public var title: String {
    switch self {
    case .notConfigured: "Push notifications are not set up"
    default: "That Firebase file was not what this server needs"
    }
  }

  public var body: String {
    switch self {
    case .notAServiceAccount(let found):
      "This looks like a \(found) file. The server needs the service account key — the "
        + "one Firebase generates under Project settings → Service accounts."
    case .malformedServiceAccount(let reason):
      "The service account key could not be read: \(reason)"
    case .malformedClientConfig(let reason):
      "The google-services.json could not be read: \(reason)"
    case .notConfigured:
      "No Firebase credentials have been uploaded, so notifications cannot be delivered."
    }
  }
}
