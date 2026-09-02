//  FirebaseProvisioner
//  Creating a Firebase project from scratch, for users who want the guided setup.
//
//  A port of `services/oauthService`, with two deliberate changes, both security fixes:
//
//    1. **Project IDs come from a CSPRNG at full length.** The current flow produces
//       `bluebubbles-[4 hex]` — 65,536 possibilities, enumerable in minutes. See
//       ProjectIdentifier.
//    2. **The locked-down rules are published at creation.** The current flow publishes
//       world-writable rules and relies on nobody finding the project. New projects are now
//       never permissive, even briefly.
//
//  The steps themselves are unchanged, because they are Google's: a project, several APIs
//  enabled on it, Firebase added, a service account, a database, an Android app registration,
//  and finally the two JSON files the server needs.
//
//  See `docs/EVENTS.md`.

import BBCore
import Foundation
import Logging

public enum ProvisioningError: BBError, Equatable, CustomStringConvertible {
  case projectCreationFailed(reason: String)
  case operationTimedOut(step: String)
  case serviceAccountUnavailable
  case clientConfigUnavailable
  /// Google will not create a Firestore database on a project with no billing account.
  /// Distinguished from a generic 403 because it is the one failure here the user can fix,
  /// and the raw message does not say what to do about it.
  case billingRequired(projectId: String)

  public var description: String {
    switch self {
    case .projectCreationFailed(let reason):
      "Google refused to create the project: \(reason)"
    case .operationTimedOut(let step):
      "Google did not finish \(step) in time. The project may still be created — "
        + "check the Firebase console before trying again."
    case .serviceAccountUnavailable:
      "The project's Firebase Admin service account did not appear. This is usually "
        + "temporary; try again in a few minutes."
    case .clientConfigUnavailable:
      "The project was created but its client configuration could not be read."
    case .billingRequired(let projectId):
      // No longer "run setup again": everything except the database exists by this
      // point, and setup resumes into the same project rather than creating another.
      "Google requires a billing account on project \(projectId) before it will create "
        + "a Firestore database. Everything else is already set up — enable billing "
        + "and continue from where setup stopped. Cloud Messaging is free and this "
        + "server's database usage is negligible."
    }
  }
}

/// A Firebase project on the signed-in account, for the picker.
public struct FirebaseProjectSummary: Sendable, Equatable, Identifiable, Hashable {
  public var id: String { projectId }
  public let projectId: String
  public let displayName: String
  public let projectNumber: String?
  /// Google reports deleted-but-not-yet-purged projects too. They cannot be adopted, so
  /// they are listed as unavailable rather than hidden — a user looking for a project they
  /// just deleted should see why it is not selectable.
  public let isActive: Bool

  public init(
    projectId: String,
    displayName: String,
    projectNumber: String? = nil,
    isActive: Bool = true
  ) {
    self.projectId = projectId
    self.displayName = displayName
    self.projectNumber = projectNumber
    self.isActive = isActive
  }
}

/// What to do about the Admin SDK key when adopting a project.
public enum ServiceAccountKeyStrategy: Sendable, Equatable {
  /// Use the key this server already holds. No IAM call is made at all.
  case reuseHeld
  /// Mint a new key. Existing keys stay valid unless `deletingExisting` is set.
  case mintNew(deletingExisting: Bool)
}

/// What adopting a project would involve, so the user can be asked before it happens.
public struct ProjectAdoptionPlan: Sendable, Equatable {
  public let projectId: String
  /// This server already holds a usable key for this project, so nothing need be minted.
  public let canReuseHeldKey: Bool
  /// The Admin SDK service account, once found.
  public let serviceAccountEmail: String?
  /// User-managed keys that already exist on that account.
  ///
  /// Only these can be deleted — Google-managed keys are Google's and are never touched.
  /// The count is what makes the "delete the old ones" choice meaningful rather than
  /// abstract.
  public let existingUserManagedKeys: Int

  public init(
    projectId: String,
    canReuseHeldKey: Bool,
    serviceAccountEmail: String? = nil,
    existingUserManagedKeys: Int = 0
  ) {
    self.projectId = projectId
    self.canReuseHeldKey = canReuseHeldKey
    self.serviceAccountEmail = serviceAccountEmail
    self.existingUserManagedKeys = existingUserManagedKeys
  }

  /// Whether there is actually a decision to put to the user.
  ///
  /// With no held key and no existing keys there is exactly one possible action — mint —
  /// and asking about it would be a dialog with one answer.
  public var needsUserDecision: Bool {
    canReuseHeldKey || existingUserManagedKeys > 0
  }
}

/// Where a provisioning run has got to, for the setup UI.
public enum ProvisioningStep: String, Sendable, CaseIterable {
  case creatingProject = "Creating the Google Cloud project"
  case enablingAPIs = "Enabling the required APIs"
  case addingFirebase = "Adding Firebase to the project"
  case creatingServiceAccount = "Generating credentials"
  case creatingDatabase = "Creating the database"
  case registeringApp = "Registering the app"
  case fetchingClientConfig = "Fetching the client configuration"
  case publishingRules = "Applying security rules"
  case done = "Finished"
}

public actor FirebaseProvisioner {

  /// APIs the project needs. Enabling one that is already on is a no-op, so the list is
  /// applied unconditionally rather than checked first.
  ///
  /// **`iam.googleapis.com` is the one that matters most**: minting the Admin SDK key is an
  /// IAM call, so leaving it off breaks the step that the whole flow exists to reach. It
  /// was missing. The reference server enables it in a method called `enableIdentityApi`,
  /// and the port read that name as Identity Toolkit — Firebase Auth, which this server
  /// does not use — and enabled that instead. So the list had a service nothing needs and
  /// was missing the one the next step depends on.
  static let requiredServices = [
    "cloudapis.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "firebase.googleapis.com",
    "firestore.googleapis.com",
  ]

  private let api: GoogleAPIClient
  private let logger: Logger
  private let onProgress: @Sendable (ProvisioningStep) async -> Void

  public init(
    api: GoogleAPIClient,
    logger: Logger = Logger(label: "bluebubbles.push.provisioning"),
    onProgress: @escaping @Sendable (ProvisioningStep) async -> Void = { _ in }
  ) {
    self.api = api
    self.logger = logger
    self.onProgress = onProgress
  }

  /// What a completed run produces: the two documents, as Google issued them.
  ///
  /// RAW bytes rather than parsed models. The parsed forms are along for convenience, but
  /// the bytes are what gets stored — `google-services.json` carries the Android API key
  /// and app ID that nothing on this server reads and no client works without, and a run
  /// that returned only the projection threw them away at the moment they were created.
  public struct Provisioned: Sendable {
    public let serviceAccount: ServiceAccount
    public let serviceAccountJSON: Data
    public let clientConfig: FirebaseClientConfig
    public let clientConfigJSON: Data
  }

  /// Every Firebase project the signed-in account can see.
  ///
  /// Offered so setup can ADOPT a project rather than always creating one. That matters
  /// beyond saving a minute of API calls: FCM registration tokens are scoped to a project,
  /// so a new project silently invalidates every client already registered against the old
  /// one. Reuse is the difference between "reconnect your phone" and nothing at all.
  public func listProjects() async throws -> [FirebaseProjectSummary] {
    // The Firebase list, not Cloud Resource Manager's: a project without Firebase cannot
    // be adopted without `addFirebase` first, and offering one that then fails several
    // steps later is worse than not offering it.
    let response = try await api.send(
      method: "GET",
      url: "https://firebase.googleapis.com/v1beta1/projects?pageSize=100"
    )
    struct Listing: Decodable {
      struct Project: Decodable {
        let projectId: String
        let displayName: String?
        let projectNumber: String?
        let state: String?
      }
      let results: [Project]?
    }
    let listing = try? JSONDecoder().decode(Listing.self, from: response)
    let projects = (listing?.results ?? []).map {
      FirebaseProjectSummary(
        projectId: $0.projectId,
        displayName: $0.displayName ?? $0.projectId,
        projectNumber: $0.projectNumber,
        isActive: ($0.state ?? "ACTIVE") == "ACTIVE"
      )
    }

    return projects.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
  }

  /// Inspects a project so the key decision can be put to the user before anything changes.
  ///
  /// - Parameter holdsKeyForProject: whether the caller already has a key for this project.
  ///   Passed in rather than read here — the Keychain belongs to the layer above.
  public func inspectForAdoption(
    projectId: String,
    holdsKeyForProject: Bool
  ) async -> ProjectAdoptionPlan {
    guard let account = try? await firebaseAdminAccount(in: projectId, deadline: .seconds(20))
    else {
      return ProjectAdoptionPlan(
        projectId: projectId, canReuseHeldKey: holdsKeyForProject
      )
    }

    let existing = await userManagedKeyNames(in: projectId, account: account.identifier)

    return ProjectAdoptionPlan(
      projectId: projectId,
      canReuseHeldKey: holdsKeyForProject,
      serviceAccountEmail: account.email,
      existingUserManagedKeys: existing.count
    )
  }

  /// Deletes the user-managed keys that existed BEFORE this run.
  ///
  /// Run after a new key has been minted, never before: deleting first and then failing to
  /// mint would leave the project with no usable key at all. Google-managed keys are
  /// excluded — they are Google's, and deleting them breaks Firebase's own internals.
  ///
  /// This is the one genuinely destructive thing setup can do, and what it breaks is any
  /// OTHER server or script still holding one of those keys. Connected devices are
  /// unaffected: FCM registrations are scoped to the project, not to a key.
  private func deleteKeys(_ names: [String]) async {
    for name in names {
      do {
        try await api.send(
          method: "DELETE",
          url: "https://iam.googleapis.com/v1/\(name)"
        )
      } catch {
        logger.warning(
          "Could not delete a previous service account key",
          metadata: [
            "error": .string(String(describing: error))
          ])
      }
    }
  }

  /// The user-managed key names on the project's Admin SDK account, right now.
  ///
  /// One function for both the count shown to the user and the set that deletion acts on,
  /// so the dialog can never offer to delete a number that differs from what it deletes.
  ///
  /// The predicate is "not explicitly Google-managed" rather than "explicitly
  /// user-managed". The request already filters server-side, and requiring the field to be
  /// present as `USER_MANAGED` means a response that omits `keyType` silently counts zero —
  /// which would make the delete option disappear rather than fail loudly. Google-managed
  /// keys are still excluded, and they are the ones that must never be touched.
  private func userManagedKeyNames(in projectId: String, account: String) async -> [String] {
    guard
      let response = try? await api.send(
        method: "GET",
        url: "https://iam.googleapis.com/v1/projects/\(projectId)"
          + "/serviceAccounts/\(account)/keys?keyTypes=USER_MANAGED"
      )
    else { return [] }
    struct Keys: Decodable {
      struct Key: Decodable {
        let name: String?
        let keyType: String?
      }
      let keys: [Key]?
    }
    let all = (try? JSONDecoder().decode(Keys.self, from: response))?.keys ?? []

    return all.filter { $0.keyType != "GOOGLE_MANAGED" }.compactMap(\.name)
  }

  /// Runs the whole flow and returns what the server needs to keep.
  ///
  /// - Parameters:
  ///   - adopting: An existing project to use. Nil creates a new one. Every step below is
  ///     written to be idempotent so adoption and creation share one path rather than
  ///     forking into two flows that drift apart.
  ///   - existingServiceAccountJSON: A key this server ALREADY holds for that project.
  ///     When present, no IAM call is made at all — the key that is already working is the
  ///     best one to keep using, and Google will not hand back the private half of any
  ///     other key that exists.
  public func provision(
    adopting adoptedProjectId: String? = nil,
    existingServiceAccountJSON: Data? = nil,
    keyStrategy: ServiceAccountKeyStrategy = .mintNew(deletingExisting: false),
    /// Published into the project's rules, so a server set up with the restart channel
    /// switched off never opens it in the first place.
    remoteRestartEnabled: Bool = true,
    displayName: String = "BlueBubbles",
    packageName: String = "com.bluebubbles.messaging"
  ) async throws -> Provisioned {
    let isAdopting = adoptedProjectId != nil
    // Full-length, CSPRNG-derived when creating. This is the fix for vulnerability #3.
    let projectId = adoptedProjectId ?? ProjectIdentifier.generate()

    if isAdopting {
      logger.info(
        "Using an existing Firebase project",
        metadata: [
          "projectId": .string(projectId)
        ])
    } else {
      logger.info(
        "Creating a Google Cloud project",
        metadata: [
          "projectId": .string(projectId),
          "entropyBits": .stringConvertible(ProjectIdentifier.entropyBits()),
        ])
    }

    // Both skipped when adopting: the project exists and already has Firebase, which is
    // what listing it from the Firebase API means.
    if !isAdopting {
      try await step(.creatingProject, onProgress) {
        try await createProject(projectId: projectId, displayName: displayName)
      }
    }

    // Run even when adopting. Enabling is idempotent and costs one batched call, and an
    // older project may predate a service this server now needs — `iam.googleapis.com`
    // in particular, without which the next step cannot mint anything.
    try await step(.enablingAPIs, onProgress) {
      try await enableRequiredServices(on: projectId)
    }

    if !isAdopting {
      try await step(.addingFirebase, onProgress) {
        try await addFirebase(to: projectId)
      }
    }

    let serviceAccountJSON: Data
    if keyStrategy == .reuseHeld, let existingServiceAccountJSON {
      // No IAM call at all. Google returns private key material ONLY when a key is
      // created — `keys.list` hands back metadata — so a key already in the Keychain is
      // the only existing key that can ever be used, and minting a second one would add
      // to the ten-key limit for nothing.
      await onProgress(.creatingServiceAccount)
      serviceAccountJSON = existingServiceAccountJSON
    } else {
      serviceAccountJSON = try await step(.creatingServiceAccount, onProgress) {
        let account = try await firebaseAdminAccount(in: projectId)

        // Captured BEFORE minting so the new key is not in the deletion set, and
        // deleted only AFTER a replacement exists — the reverse order leaves the
        // project with no usable key if the mint then fails.
        let previous: [String]
        if case .mintNew(deletingExisting: true) = keyStrategy {
          previous = await userManagedKeyNames(
            in: projectId, account: account.identifier
          )
        } else {
          previous = []
        }

        // Additive by default: existing keys stay valid, so another server using this
        // project keeps working. The reference server always deletes user-managed
        // keys first, which silently breaks exactly that — here it happens only when
        // the user asked for it.
        let minted = try await generateServiceAccount(for: projectId)

        if !previous.isEmpty {
          await deleteKeys(previous)
        }
        return minted
      }
    }

    try await step(.creatingDatabase, onProgress) {
      try await createFirestore(in: projectId)
    }

    let appName = try await step(.registeringApp, onProgress) {
      try await registerAndroidApp(in: projectId, packageName: packageName)
    }

    let clientConfigJSON = try await step(.fetchingClientConfig, onProgress) {
      try await fetchClientConfig(appName: appName)
    }

    // Before the project is ever announced anywhere. The current flow publishes
    // permissive rules here and tightens them never.
    try await step(.publishingRules, onProgress) {
      let rules = SecurityRulesManager(
        api: api, projectId: projectId, remoteRestartEnabled: remoteRestartEnabled
      )
      try await rules.publish(kind: .firestore)
    }

    await onProgress(.done)
    logger.info("Provisioning finished", metadata: ["projectId": .string(projectId)])

    return Provisioned(
      serviceAccount: try ServiceAccount.parse(serviceAccountJSON),
      serviceAccountJSON: serviceAccountJSON,
      clientConfig: try FirebaseClientConfig.parse(clientConfigJSON),
      clientConfigJSON: clientConfigJSON
    )
  }

  /// Runs one provisioning step: reports it to the UI, and names it if it throws.
  ///
  /// The log line on failure is the point. Without it a failure surfaces as a bare
  /// `GoogleAPIError` carrying a URL, and working out WHICH of the eight steps was in
  /// progress means reading that URL and knowing the sequence by heart. The error itself is
  /// rethrown untouched — the UI still shows the actionable message.
  private func step<T>(
    _ which: ProvisioningStep,
    _ onProgress: @Sendable (ProvisioningStep) async -> Void,
    _ body: () async throws -> T
  ) async throws -> T {
    await onProgress(which)
    do {
      return try await body()
    } catch {
      logger.error(
        "Provisioning failed",
        metadata: [
          "step": .string(which.rawValue),
          "error": .string(String(describing: error)),
        ])
      throw error
    }
  }

  // MARK: - Steps

  private func createProject(projectId: String, displayName: String) async throws {
    let body = try JSONSerialization.data(withJSONObject: [
      "projectId": projectId,
      "displayName": displayName,
    ])
    let response = try await api.send(
      method: "POST",
      url: "https://cloudresourcemanager.googleapis.com/v3/projects",
      body: body
    )
    try await awaitOperation(
      named: operationName(in: response),
      on: "https://cloudresourcemanager.googleapis.com/v3",
      step: "project creation"
    )
  }

  /// Enables every required API in ONE call.
  ///
  /// `:batchEnable` takes the whole list and returns a single long-running operation.
  /// Enabling them one at a time cost a POST plus its own polling loop per service — 26
  /// seconds of a 105-second run, for five services that Google is happy to switch on
  /// together. Enabling is idempotent, so the list is applied without checking first.
  private func enableRequiredServices(on projectId: String) async throws {

    let response = try await api.send(
      method: "POST",
      url: "https://serviceusage.googleapis.com/v1/projects/\(projectId)/services:batchEnable",
      body: try JSONSerialization.data(withJSONObject: [
        "serviceIds": Self.requiredServices
      ])
    )
    try await awaitOperation(
      named: operationName(in: response),
      on: "https://serviceusage.googleapis.com/v1",
      step: "enabling the required APIs"
    )
  }

  private func addFirebase(to projectId: String) async throws {
    let response = try await api.send(
      method: "POST",
      url: "https://firebase.googleapis.com/v1beta1/projects/\(projectId):addFirebase",
      body: Data("{}".utf8)
    )
    try await awaitOperation(
      named: operationName(in: response),
      on: "https://firebase.googleapis.com/v1beta1",
      step: "adding Firebase"
    )
  }

  /// Identifies the project's Firebase Admin service account.
  struct AdminAccount: Sendable {
    /// What the IAM URLs address the account by — its unique ID, or the email as a
    /// fallback. Both are accepted by the API.
    let identifier: String
    let email: String?
  }

  /// Finds the project's Firebase Admin service account by ASKING, not by guessing.
  ///
  /// The address is not derivable. Google appends a suffix to it —
  /// `firebase-adminsdk-a1b2c@…` historically, `firebase-adminsdk-fbsvc@…` on projects
  /// created more recently — so a constructed `firebase-adminsdk@{project}` never exists for
  /// ANY project. Guessing it makes every guided setup 404 twelve times over sixty seconds
  /// and report the account as "not ready yet", which reads as a slow provisioning run
  /// rather than as a defect.
  ///
  /// The reference server lists the accounts and matches on `displayName`. Matching on the
  /// email prefix as well costs nothing and survives Google renaming the display name.
  ///
  /// The account is created by `addFirebase`, but not instantly — hence the deadline.
  private func firebaseAdminAccount(
    in projectId: String,
    deadline timeout: Duration = .seconds(180)
  ) async throws -> AdminAccount {
    struct Accounts: Decodable {
      struct Account: Decodable {
        let email: String?
        let uniqueId: String?
        let displayName: String?
      }
      let accounts: [Account]?
    }

    var lastError: String?
    let deadline = ContinuousClock.now + timeout
    var attempt = 0

    while ContinuousClock.now < deadline {
      attempt += 1
      do {
        let response = try await api.send(
          method: "GET",
          url: "https://iam.googleapis.com/v1/projects/\(projectId)/serviceAccounts"
        )
        let accounts =
          (try? JSONDecoder().decode(Accounts.self, from: response))?
          .accounts ?? []

        if let match = accounts.first(where: {
          $0.displayName == "firebase-adminsdk"
            || ($0.email?.hasPrefix("firebase-adminsdk") ?? false)
        }), let identifier = match.uniqueId ?? match.email {
          return AdminAccount(identifier: identifier, email: match.email)
        }

      } catch {
        // Retried rather than fatal: the IAM API was enabled moments ago and can
        // briefly refuse calls while that propagates.
        lastError = String(describing: error)
      }

      try await Task.sleep(for: .seconds(5))
    }

    logger.error(
      "The Firebase Admin service account never appeared",
      metadata: [
        "projectId": .string(projectId),
        "lastError": .string(lastError ?? "none — the account simply was not listed"),
      ])
    throw ProvisioningError.serviceAccountUnavailable
  }

  private func generateServiceAccount(for projectId: String) async throws -> Data {
    // Discovered, not constructed. See `firebaseAdminAccount`.
    let email = try await firebaseAdminAccount(in: projectId).identifier

    for attempt in 1...12 {
      do {
        let response = try await api.send(
          method: "POST",
          url: "https://iam.googleapis.com/v1/projects/\(projectId)"
            + "/serviceAccounts/\(email)/keys",
          body: try JSONSerialization.data(withJSONObject: [
            "privateKeyType": "TYPE_GOOGLE_CREDENTIALS_FILE"
          ])
        )
        struct Key: Decodable { let privateKeyData: String }
        guard let encoded = try? JSONDecoder().decode(Key.self, from: response),
          let decoded = Data(base64Encoded: encoded.privateKeyData)
        else { throw ProvisioningError.serviceAccountUnavailable }
        // Parsed only to VALIDATE. The bytes are what is returned, so the stored
        // credential stays byte-identical to what Google issued.
        _ = try ServiceAccount.parse(decoded)
        return decoded
      } catch {
        guard attempt < 12 else { throw ProvisioningError.serviceAccountUnavailable }
        logger.debug(
          "The service account is not ready yet; waiting",
          metadata: [
            "attempt": .stringConvertible(attempt)
          ])
        try await Task.sleep(for: .seconds(5))
      }
    }
    throw ProvisioningError.serviceAccountUnavailable
  }

  private func createFirestore(in projectId: String) async throws {
    let body = try JSONSerialization.data(withJSONObject: [
      "type": "FIRESTORE_NATIVE",
      // `nam5` is the multi-region Google itself defaults to in the console.
      "locationId": "nam5",
    ])
    do {
      let response = try await api.send(
        method: "POST",
        url: "https://firestore.googleapis.com/v1/projects/\(projectId)"
          + "/databases?databaseId=(default)",
        body: body
      )
      try await awaitOperation(
        named: operationName(in: response),
        on: "https://firestore.googleapis.com/v1",
        step: "creating Firestore"
      )
    } catch let error as GoogleAPIError {
      // A project that already has a database is fine — this flow is re-runnable.
      if case .requestFailed(let status, let code, let message) = error {
        if code == "ALREADY_EXISTS" || status == 409 { return }

        // Google refuses to create a Firestore database on a project with no billing
        // account. Reported as its own case: it is the only failure in this flow the
        // user can actually resolve, and Google's own message does not say how.
        //
        // Matched on the MESSAGE, not on the status code. The reference server keys
        // on 403 specifically, but this arrives as `PERMISSION_DENIED`,
        // `FAILED_PRECONDITION` or a plain 400 depending on the account and the API
        // surface — and a detection that misses reports a raw permission error the
        // user has no way to act on. The word "billing" is the reliable part.
        if message.localizedCaseInsensitiveContains("billing") {
          throw ProvisioningError.billingRequired(projectId: projectId)
        }
      }
      throw error
    }
  }

  /// The existing Android app for our package name, if the project already has one.
  ///
  /// Checked before registering. A project that has been through setup before — or that the
  /// user set up by hand — already has this app, and registering a second one for the same
  /// package name produces a duplicate whose `google-services.json` may not be the one
  /// clients are using. Adoption makes this the common case rather than the rare one.
  private func existingAndroidApp(in projectId: String, packageName: String) async -> String? {
    do {
      let response = try await api.send(
        method: "GET",
        url: "https://firebase.googleapis.com/v1beta1/projects/\(projectId)/androidApps"
      )
      struct Listing: Decodable {
        struct App: Decodable {
          let name: String?
          let packageName: String?
        }
        let apps: [App]?
      }
      let apps = (try? JSONDecoder().decode(Listing.self, from: response))?.apps ?? []
      guard let match = apps.first(where: { $0.packageName == packageName })?.name else {
        return nil
      }
      return match
    } catch {
      // Not fatal: a project with no apps yet answers this fine, and any other failure
      // is better handled by attempting the registration than by aborting here.
      return nil
    }
  }

  private func registerAndroidApp(in projectId: String, packageName: String) async throws -> String
  {
    if let existing = await existingAndroidApp(in: projectId, packageName: packageName) {
      return existing
    }

    let body = try JSONSerialization.data(withJSONObject: [
      "packageName": packageName,
      "displayName": "BlueBubbles",
    ])
    let response = try await api.send(
      method: "POST",
      url: "https://firebase.googleapis.com/v1beta1/projects/\(projectId)/androidApps",
      body: body
    )
    // Checked BEFORE polling. When Google answers with the created app rather than with
    // an operation, the payload's `name` is `projects/…/androidApps/…` — which
    // `operationName` cannot tell apart from an operation name, so it would be polled as
    // one: three minutes of GETs against an app's own URL, ending in "Google did not
    // finish registering the app in time" about an app that was registered immediately.
    if let appName = Self.appName(in: response) { return appName }

    let operation = try await awaitOperation(
      named: operationName(in: response),
      on: "https://firebase.googleapis.com/v1beta1",
      step: "registering the app"
    )
    guard let appName = Self.appName(in: operation) else {
      throw ProvisioningError.clientConfigUnavailable
    }
    return appName
  }

  /// The `projects/…/androidApps/…` resource name, wherever it is in this payload.
  static func appName(in data: Data?) -> String? {
    guard let data else { return nil }
    struct Payload: Decodable {
      struct Response: Decodable { let name: String? }
      let name: String?
      let response: Response?
    }
    guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
    if let name = payload.response?.name, name.contains("/androidApps/") { return name }
    // Guarded on the path rather than taken on trust: an operation's own `name` is
    // `operations/…`, and handing that to the config endpoint asks Google for the
    // configuration of an operation.
    if let name = payload.name, name.contains("/androidApps/") { return name }
    return nil
  }

  /// The `google-services.json` Google generated, as bytes.
  ///
  /// Returned whole, NOT decoded into `FirebaseClientConfig` first. Keeping only that
  /// projection discards the Android API key and app ID at the one moment they exist, which
  /// makes the guided path produce the same unusable client configuration as the import
  /// path, from the other direction.
  private func fetchClientConfig(appName: String) async throws -> Data {
    let response = try await api.send(
      method: "GET",
      url: "https://firebase.googleapis.com/v1beta1/\(appName)/config"
    )
    struct Config: Decodable { let configFileContents: String }
    guard let wrapper = try? JSONDecoder().decode(Config.self, from: response),
      let decoded = Data(base64Encoded: wrapper.configFileContents),
      (try? FirebaseClientConfig.parse(decoded)) != nil
    else { throw ProvisioningError.clientConfigUnavailable }
    return decoded
  }

  // MARK: - Long-running operations

  /// The name of the operation a call started, or nil when it completed inline.
  private func operationName(in response: Data) -> String? {
    struct Operation: Decodable {
      let name: String?
      let done: Bool?
    }
    guard let operation = try? JSONDecoder().decode(Operation.self, from: response) else {
      return nil
    }
    // Already finished: nothing to poll.
    if operation.done == true { return nil }
    // Service Usage answers an already-enabled API with this sentinel instead of a real
    // operation name. Polling it produces a 404 that reads like a failure, which is why
    // the reference special-cases it too.
    if operation.name?.hasSuffix("DONE_OPERATION") == true { return nil }
    return operation.name
  }

  /// Polls a long-running operation until it finishes.
  ///
  /// Most of these Google APIs answer immediately with an operation that is still running;
  /// using the project before it exists produces confusing failures several steps later.
  ///
  /// - Parameter host: The API base the operation belongs to. **Operations are polled on the
  ///   service that issued them** — `serviceusage` operations live under
  ///   `serviceusage.googleapis.com`, Firebase's under `firebase.googleapis.com`, and so on.
  ///   Polling them all against Cloud Resource Manager, as this did, 404s on every step after
  ///   project creation: enabling the APIs would appear to hang and then time out with a
  ///   message about the wrong thing. The reference polls per host for exactly this reason.
  @discardableResult
  private func awaitOperation(
    named name: String?,
    on host: String,
    step: String,
    timeout: Duration = .seconds(180)
  ) async throws -> Data? {
    guard let name else {
      return nil
    }

    var polls = 0
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      polls += 1
      let response = try await api.send(method: "GET", url: "\(host)/\(name)")
      struct Operation: Decodable {
        struct Failure: Decodable { let message: String? }
        let done: Bool?
        let error: Failure?
        let response: [String: AnyDecodable]?
      }
      if let operation = try? JSONDecoder().decode(Operation.self, from: response),
        operation.done == true
      {
        if let message = operation.error?.message {
          throw ProvisioningError.projectCreationFailed(reason: message)
        }
        return response
      }

      // Escalating, not a flat three seconds. Most of these operations finish within a
      // second or two of the first poll, and a fixed interval spent the same three
      // seconds waiting on every one of them regardless — several seconds of pure
      // idling per run, in a flow whose slowness is its main usability problem. The
      // interval still grows to the old value for the operations that genuinely take
      // minutes, so nothing is polled harder for longer.
      let interval = min(3.0, 0.5 * Double(polls))
      try await Task.sleep(for: .seconds(interval))
    }

    throw ProvisioningError.operationTimedOut(step: step)
  }
}

/// Decodes any JSON value without modelling it. Used only to let an operation's opaque
/// `response` field decode without failing.
struct AnyDecodable: Decodable {
  init(from decoder: any Decoder) throws {
    _ = try? decoder.singleValueContainer()
  }
}

extension ProvisioningError {
  public var code: String {
    switch self {
    case .projectCreationFailed: "provisioning.project_creation_failed"
    case .operationTimedOut: "provisioning.operation_timed_out"
    case .serviceAccountUnavailable: "provisioning.service_account_unavailable"
    case .clientConfigUnavailable: "provisioning.client_config_unavailable"
    case .billingRequired: "provisioning.billing_required"
    }
  }

  public var domain: String { "Push" }

  /// Guided setup is something the user is watching happen, so every failure in it is one
  /// they need to see.
  public var isUserFacing: Bool { true }

  public var title: String {
    switch self {
    case .billingRequired: "This Google project needs billing enabled"
    default: "Firebase setup could not finish"
    }
  }

  /// Each case already writes a sentence a person can act on.
  public var body: String { description }
}
