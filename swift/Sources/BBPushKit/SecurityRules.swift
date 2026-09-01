//  SecurityRules
//  The Firebase rulesets, and repairing them on every start.
//
//  Three of the four vulnerabilities in the 2023 report are rules-level. The rules the current
//  server publishes — and the ones its manual setup documentation tells users to paste — make
//  the config document **world-writable**. Anyone who guesses a project ID can rewrite
//  `serverUrl` and point every one of that user's clients at a proxy they control, capturing
//  plaintext messages and the server password. Project IDs were `bluebubbles-[4 hex]`: 65,536
//  possibilities, which is not a search space.
//
//  What is fixed, and what deliberately is not
//  ------------------------------------------
//  **Read on `/server/config` stays open.** Unauthenticated clients need it and there is no
//  authentication mechanism without adopting Firebase Auth, which was ruled out. So an
//  attacker who enumerates a project still learns that a server exists and where — but can no
//  longer move it, and reaching it lands on the rate-limited, lockout-protected auth path.
//
//  **Write on `/server/config` is denied.** This is the actual fix, and it costs nothing:
//  clients only ever read that document, and the server writes it through a service account,
//  which bypasses rules entirely. Invisible to every existing client; closes the redirection
//  attack outright.
//
//  **Write on `/server/commands` stays open,** because clients DO write it — that document
//  backs the "restart server" button. Locking it would break a shipping feature, which the
//  compatibility contract forbids. The damage is bounded server-side instead; see
//  RemoteRestartWatcher.
//
//  See `.claude/docs/decisions.md`.

import Foundation

public enum SecurityRuleset {

  /// Firestore rules, least privilege.
  ///
  /// Order matters: the deny-by-default match is written first and the specific paths after
  /// it. Firestore evaluates every matching rule and allows if ANY grants access, so this is
  /// not a fallthrough — the specific `allow read` on the config document is what makes it
  /// readable, and nothing else is.
  /// - Parameter remoteRestartEnabled: when false, the restart channel is denied outright.
  ///
  ///   This is what makes the "Allow clients to restart this server" switch mean something
  ///   in Firebase rather than only in this process. With it off, the server stops POLLING
  ///   the commands document — but a static ruleset left that document world-writable, so
  ///   the channel the switch is meant to close stayed open to anyone who knew the project
  ///   ID. That open channel is the vulnerability the switch exists for, so turning the
  ///   feature off has to close it where it actually lives.
  public static func firestore(remoteRestartEnabled: Bool = true) -> String {
    let commands =
      remoteRestartEnabled
      ? """
        match /server/commands { allow read: if false;
                                 allow write: if true; }
      """
      : """
        match /server/commands { allow read, write: if false; }
      """
    return """
      rules_version = '2';
      service cloud.firestore {
        match /databases/{database}/documents {
          match /{document=**}   { allow read, write: if false; }
          match /server/config   { allow read: if true;
                                   allow write: if false; }
      \(commands)
        }
      }
      """
  }

  /// Realtime Database equivalent.
  ///
  /// Denied at the root, with reads scoped to the one node clients use and writes to the one
  /// node they write. The current rules set `".read": true` at the ROOT, which exposes every
  /// value in the database to anyone who knows the project.
  public static func realtimeDatabase(remoteRestartEnabled: Bool = true) -> String {
    """
    {
      "rules": {
        ".read": false,
        ".write": false,
        "config": {
          "serverUrl": { ".read": true, ".write": false },
          "nextRestart": { ".read": false, ".write": \(remoteRestartEnabled) }
        }
      }
    }
    """
  }

  /// Whether a live ruleset is one of the permissive shapes that must be replaced.
  ///
  /// Deliberately a check for DANGER rather than for an exact match. Rulesets get edited by
  /// hand, reformatted by the console, and written by several generations of setup
  /// instructions; demanding textual equality would rewrite rules that were already safe and
  /// still miss a permissive one that happened to be spelled differently. What matters is
  /// whether a write is granted unconditionally somewhere it should not be.
  /// - Parameter remoteRestartEnabled: with restart disabled, an unconditional write on the
  ///   commands document is no longer acceptable — it is precisely what should have been
  ///   revoked. Without this the rules check reported "nothing needed changing" no matter
  ///   which way the switch was set, which is what made the switch look inert.
  public static func isPermissive(
    _ rules: String,
    kind: FirebaseDatabaseKind,
    remoteRestartEnabled: Bool = true
  ) -> Bool {
    let normalized =
      rules
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "\n", with: "")
      .replacingOccurrences(of: "\t", with: "")
      .lowercased()

    switch kind {
    case .firestore:
      // The documented-but-dangerous form, and its variants.
      if normalized.contains("allowread,write:iftrue") { return true }
      if normalized.contains("allowwrite:iftrue") {
        // Writable is only acceptable on the commands document, and only while the
        // restart channel is meant to be open at all.
        guard remoteRestartEnabled else { return true }
        return !isWriteConfinedToCommands(normalized)
      }
      return false

    case .realtime:
      // `".write": true` at the root, or a root-level `".read": true`, are both the
      // shapes the current server publishes and both are too broad.
      guard let rulesBody = normalized.range(of: "\"rules\":{") else {
        return normalized.contains("\".write\":true") || normalized.contains("\".read\":true")
      }
      let tail = normalized[rulesBody.upperBound...]
      // A permission granted before any nested node opens is a root-level grant.
      let firstNested = tail.firstIndex(of: "{") ?? tail.endIndex
      let rootScope = tail[..<firstNested]
      if rootScope.contains("\".write\":true") || rootScope.contains("\".read\":true") {
        return true
      }
      // With restart disabled, a writable `nextRestart` is the grant that should have
      // been revoked.
      return !remoteRestartEnabled
        && normalized.contains("\"nextrestart\":{\".read\":false,\".write\":true}")
    }
  }

  /// Whether the only unconditional write in a Firestore ruleset is on `/server/commands`.
  private static func isWriteConfinedToCommands(_ normalized: String) -> Bool {
    // Every `match` block that grants an unconditional write must be the commands one.
    var remaining = Substring(normalized)
    while let match = remaining.range(of: "match/") {
      let afterMatch = remaining[match.upperBound...]
      guard let blockStart = afterMatch.firstIndex(of: "{") else { break }
      let path = afterMatch[..<blockStart]
      guard let blockEnd = afterMatch[blockStart...].firstIndex(of: "}") else { break }
      let block = afterMatch[blockStart...blockEnd]

      if block.contains("allowwrite:iftrue") || block.contains("allowread,write:iftrue") {
        guard path.contains("server/commands") else { return false }
      }
      remaining = afterMatch[blockEnd...]
    }
    return true
  }
}

// MARK: - Publishing

/// What a remediation pass did, so the caller can tell the user precisely.
public struct RemediationOutcome: Sendable, Equatable {
  public let kind: FirebaseDatabaseKind
  public let wasPermissive: Bool
  public let published: Bool
  /// Plain-language description of what was wrong, for the alert.
  public let finding: String?

  public init(
    kind: FirebaseDatabaseKind,
    wasPermissive: Bool,
    published: Bool,
    finding: String? = nil
  ) {
    self.kind = kind
    self.wasPermissive = wasPermissive
    self.published = published
    self.finding = finding
  }
}

/// Reads and writes a project's security rules.
public actor SecurityRulesManager {

  private let api: GoogleAPIClient
  private let projectId: String
  private let databaseURL: String?
  /// What the user asked for, which decides both what is PUBLISHED and what counts as
  /// permissive. Without it the rules are the same either way and the switch has no visible
  /// effect at all.
  private let remoteRestartEnabled: Bool

  public init(
    api: GoogleAPIClient,
    projectId: String,
    databaseURL: String? = nil,
    remoteRestartEnabled: Bool = true
  ) {
    self.remoteRestartEnabled = remoteRestartEnabled
    self.api = api
    self.projectId = projectId
    self.databaseURL = databaseURL
  }

  /// Fetches the live ruleset, compares it, and publishes the locked-down one if needed.
  ///
  /// Runs on every start, for every install, with no user action — which is the point.
  /// The users at risk are precisely the ones who followed setup instructions years ago and
  /// will never revisit them.
  public func remediate(kind: FirebaseDatabaseKind) async throws -> RemediationOutcome {
    let current = try await currentRules(kind: kind)

    guard
      SecurityRuleset.isPermissive(
        current, kind: kind, remoteRestartEnabled: remoteRestartEnabled
      )
    else {
      return RemediationOutcome(kind: kind, wasPermissive: false, published: false)
    }

    try await publish(kind: kind)
    return RemediationOutcome(
      kind: kind,
      wasPermissive: true,
      published: true,
      finding: Self.finding(for: kind)
    )
  }

  static func finding(for kind: FirebaseDatabaseKind) -> String {
    switch kind {
    case .firestore:
      """
      Your Firebase security rules allowed anyone to WRITE to the document holding this \
      server's address. Anyone who guessed your project ID could have pointed your \
      devices at a server they controlled. Reading that document is still allowed, \
      because your devices need it; writing is now denied, which only the server itself \
      ever did.
      """
    case .realtime:
      """
      Your Realtime Database rules allowed anyone to READ AND WRITE the whole database, \
      including this server's address. Access is now limited to the two values your \
      devices actually use.
      """
    }
  }

  // MARK: Firestore rules, via the Firebase Rules API

  public func currentRules(kind: FirebaseDatabaseKind) async throws -> String {
    switch kind {
    case .firestore: try await currentFirestoreRules()
    case .realtime: try await currentRealtimeRules()
    }
  }

  public func publish(kind: FirebaseDatabaseKind) async throws {
    switch kind {
    case .firestore: try await publishFirestoreRules()
    case .realtime: try await publishRealtimeRules()
    }
  }

  private func currentFirestoreRules() async throws -> String {
    // The release names the ruleset currently serving `cloud.firestore`.
    let release = try await api.send(
      method: "GET",
      url: "https://firebaserules.googleapis.com/v1/projects/\(projectId)/releases/cloud.firestore"
    )
    struct Release: Decodable { let rulesetName: String }
    guard let name = try? JSONDecoder().decode(Release.self, from: release).rulesetName else {
      throw GoogleAPIError.decodingFailed(reason: "no ruleset is released for cloud.firestore")
    }

    let ruleset = try await api.send(
      method: "GET",
      url: "https://firebaserules.googleapis.com/v1/\(name)"
    )
    struct Ruleset: Decodable {
      struct Source: Decodable {
        struct File: Decodable { let content: String }
        let files: [File]
      }
      let source: Source
    }
    guard let decoded = try? JSONDecoder().decode(Ruleset.self, from: ruleset),
      let content = decoded.source.files.first?.content
    else {
      throw GoogleAPIError.decodingFailed(reason: "ruleset carried no source")
    }
    return content
  }

  private func publishFirestoreRules() async throws {
    // Two steps: create a ruleset, then point the release at it. There is no way to
    // update a release's rules in place.
    let createBody = try JSONSerialization.data(withJSONObject: [
      "source": [
        "files": [
          [
            "name": "firestore.rules",
            "content": SecurityRuleset.firestore(remoteRestartEnabled: remoteRestartEnabled),
          ]
        ]
      ]
    ])
    let created = try await api.send(
      method: "POST",
      url: "https://firebaserules.googleapis.com/v1/projects/\(projectId)/rulesets",
      body: createBody
    )
    struct Created: Decodable { let name: String }
    guard let name = try? JSONDecoder().decode(Created.self, from: created).name else {
      throw GoogleAPIError.decodingFailed(reason: "ruleset creation returned no name")
    }

    let releaseName = "projects/\(projectId)/releases/cloud.firestore"

    // PATCH first, then CREATE on 404.
    //
    // PATCH alone was the assumption that "a release exists on any project that has ever
    // had rules" — which is true, and misses the one caller for which it is not. A
    // freshly provisioned project has never had rules, so its `cloud.firestore` release
    // does not exist yet and `PATCH` answers 404 NOT_FOUND. Guided setup therefore failed
    // on its last step, having already created the project, the key and the app.
    //
    // Ordered PATCH-then-POST rather than the reverse because the repeated caller is rule
    // remediation on an existing project at every push start; that path keeps its single
    // request, and only the once-per-project case pays for the extra round trip.
    do {
      try await api.send(
        method: "PATCH",
        url: "https://firebaserules.googleapis.com/v1/\(releaseName)",
        body: try JSONSerialization.data(withJSONObject: [
          // `UpdateReleaseRequest` wraps the resource.
          "release": ["name": releaseName, "rulesetName": name]
        ])
      )
    } catch let error as GoogleAPIError {
      guard case .requestFailed(let status, _, _) = error, status == 404 else { throw error }

      // `projects.releases.create` takes the bare `Release`, NOT the wrapped update
      // request — sending the PATCH body here is accepted and silently releases
      // nothing, which would leave the project on Firebase's default rules.
      try await api.send(
        method: "POST",
        url: "https://firebaserules.googleapis.com/v1/projects/\(projectId)/releases",
        body: try JSONSerialization.data(withJSONObject: [
          "name": releaseName,
          "rulesetName": name,
        ])
      )
    }
  }

  // MARK: Realtime Database rules, via the database's own REST endpoint

  private func realtimeRulesURL() throws -> String {
    guard let databaseURL, !databaseURL.isEmpty else {
      throw GoogleAPIError.decodingFailed(reason: "no Realtime Database URL is configured")
    }
    return databaseURL.hasSuffix("/")
      ? "\(databaseURL).settings/rules.json"
      : "\(databaseURL)/.settings/rules.json"
  }

  private func currentRealtimeRules() async throws -> String {
    let data = try await api.send(method: "GET", url: try realtimeRulesURL())
    return String(decoding: data, as: UTF8.self)
  }

  private func publishRealtimeRules() async throws {
    try await api.send(
      method: "PUT",
      url: try realtimeRulesURL(),
      body: Data(SecurityRuleset.realtimeDatabase(remoteRestartEnabled: remoteRestartEnabled).utf8)
    )
  }
}
