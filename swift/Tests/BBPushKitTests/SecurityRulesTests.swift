//  SecurityRulesTests
//  The rulesets that close three of the four reported vulnerabilities.
//
//  These assertions are the security fix. If `isPermissive` stops recognising the shape the
//  old setup instructions produce, auto-remediation silently stops running and every affected
//  install stays world-writable — with no symptom, because the server works fine either way.

import Foundation
import Testing

@testable import BBPushKit

@Suite("Firestore rules")
struct FirestoreRulesTests {

  /// The exact form the manual setup documentation told users to paste.
  @Test("The documented permissive ruleset is recognised")
  func documentedPermissiveIsCaught() {
    let rules = """
      rules_version = '2';
      service cloud.firestore {
        match /databases/{database}/documents {
          match /{document=**} {
            allow read, write: if true;
          }
        }
      }
      """
    #expect(SecurityRuleset.isPermissive(rules, kind: .firestore))
  }

  /// Whitespace and formatting vary — the console reformats, people hand-edit. Matching on
  /// exact text would miss most real instances.
  @Test("Formatting does not hide a permissive rule")
  func formattingIsIgnored() {
    let compact =
      "rules_version='2';service cloud.firestore{match /databases/{d}/documents{match /{document=**}{allow read,write:if true;}}}"
    #expect(SecurityRuleset.isPermissive(compact, kind: .firestore))
  }

  /// The whole point: our own ruleset must not be flagged, or every start would republish
  /// it and raise an alert.
  @Test("The locked-down ruleset is not flagged")
  func ourRulesetIsClean() {
    #expect(!SecurityRuleset.isPermissive(SecurityRuleset.firestore(), kind: .firestore))
  }

  /// `/server/commands` is deliberately world-writable, because clients write it to ask for
  /// a restart. Flagging that would mean rewriting our own correct rules forever.
  @Test("An unconditional write confined to /server/commands is allowed")
  func commandsWriteIsPermitted() {
    let rules = """
      rules_version = '2';
      service cloud.firestore {
        match /databases/{database}/documents {
          match /{document=**}   { allow read, write: if false; }
          match /server/commands { allow read: if false;
                                   allow write: if true; }
        }
      }
      """
    #expect(!SecurityRuleset.isPermissive(rules, kind: .firestore))
  }

  /// The actual attack: a writable config document lets anyone redirect every client.
  @Test("An unconditional write on /server/config is caught")
  func configWriteIsCaught() {
    let rules = """
      rules_version = '2';
      service cloud.firestore {
        match /databases/{database}/documents {
          match /server/config { allow read: if true;
                                 allow write: if true; }
        }
      }
      """
    #expect(SecurityRuleset.isPermissive(rules, kind: .firestore))
  }

  /// Read stays open — clients are unauthenticated and need the address. Denying it would
  /// break every client, which is why the fix is write-only.
  @Test("Our ruleset keeps config readable and denies writing it")
  func ourRulesetShape() {
    let rules = SecurityRuleset.firestore()
    #expect(rules.contains("match /server/config"))
    #expect(rules.contains("allow read: if true"))
    #expect(rules.contains("allow write: if false"))
    // Deny-by-default underneath everything.
    #expect(rules.contains("match /{document=**}   { allow read, write: if false; }"))
    // And the restart channel is preserved.
    #expect(rules.contains("match /server/commands"))
  }
}

@Suite("Realtime Database rules")
struct RealtimeRulesTests {

  /// What the current server publishes: readable at the ROOT, which exposes the entire
  /// database to anyone who knows the project.
  @Test("A root-level read grant is caught")
  func rootReadIsCaught() {
    let rules = """
      {
        "rules": {
          ".read": true,
          ".write": false,
          "config": { "nextRestart": { ".write": true } }
        }
      }
      """
    #expect(SecurityRuleset.isPermissive(rules, kind: .realtime))
  }

  @Test("A root-level write grant is caught")
  func rootWriteIsCaught() {
    let rules = #"{"rules": {".read": false, ".write": true}}"#
    #expect(SecurityRuleset.isPermissive(rules, kind: .realtime))
  }

  @Test("The locked-down Realtime ruleset is not flagged")
  func ourRulesetIsClean() {
    #expect(
      !SecurityRuleset.isPermissive(
        SecurityRuleset.realtimeDatabase(), kind: .realtime
      ))
  }

  /// Scoped grants on the two nodes clients use are correct, not permissive.
  @Test("Our ruleset scopes read to serverUrl and write to nextRestart")
  func ourRulesetShape() {
    let rules = SecurityRuleset.realtimeDatabase()
    #expect(rules.contains("\"serverUrl\": { \".read\": true, \".write\": false }"))
    #expect(rules.contains("\"nextRestart\": { \".read\": false, \".write\": true }"))
  }
}

@Suite("Project identifiers")
struct ProjectIdentifierTests {

  /// The old scheme was `bluebubbles-[4 hex]`: 16 bits, 65,536 possibilities. That is a
  /// lookup table, not a search space.
  @Test("Generated identifiers carry far more entropy than the old scheme")
  func entropyImprovement() {
    let bits = ProjectIdentifier.entropyBits()
    #expect(bits >= 80, "expected substantially more than the old 16 bits, got \(bits)")
  }

  @Test("Identifiers respect Google's format and length limits")
  func formatIsValid() {
    for _ in 0..<200 {
      let identifier = ProjectIdentifier.generate()
      #expect(identifier.count <= ProjectIdentifier.maximumLength)
      #expect(identifier.count >= ProjectIdentifier.minimumLength)
      #expect(identifier.first?.isLetter == true)
      #expect(identifier.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" })
    }
  }

  /// Collisions would be a provisioning failure; more importantly, repetition would mean
  /// the generator is not random at all.
  @Test("Identifiers do not repeat")
  func identifiersAreUnique() {
    let generated = Set((0..<500).map { _ in ProjectIdentifier.generate() })
    #expect(generated.count == 500)
  }

  /// The alphabet excludes look-alike characters, so an ID read off a screen is unambiguous.
  @Test("The alphabet omits ambiguous characters and stays a power of two")
  func alphabetShape() {
    #expect(ProjectIdentifier.alphabet.count == 32, "a non-power-of-two alphabet biases the modulo")
    for character in ["l", "o", "0", "1"] {
      #expect(!ProjectIdentifier.alphabet.contains(Character(character)))
    }
  }

  /// Existing installs keep their IDs — GCP cannot rename a project. Detecting the old
  /// shape is for explaining that to the user, not for fixing it.
  @Test("Legacy low-entropy identifiers are recognised")
  func legacyDetection() {
    #expect(ProjectIdentifier.isLowEntropyLegacy("bluebubbles-1a2b"))
    #expect(ProjectIdentifier.isLowEntropyLegacy("bluebubblesapp-abcde"))
    #expect(!ProjectIdentifier.isLowEntropyLegacy(ProjectIdentifier.generate()))
  }
}

/// Publishing the ruleset onto a project's `cloud.firestore` release.
///
/// The release is a separate resource from the ruleset, and the call to point one at the
/// other differs depending on whether it already exists. Getting that wrong broke guided
/// setup on its final step, after the project, the key and the app had all been created.
@Suite("Releasing Firestore rules")
struct FirestoreReleaseTests {

  /// Answers per (method, URL-fragment), so a 404 can be scripted for one verb only.
  private actor Fake: HTTPPerforming {
    struct Call: Equatable {
      let method: String
      let url: String
      let body: String
    }

    private(set) var calls: [Call] = []
    let patchStatus: UInt

    init(patchStatus: UInt) { self.patchStatus = patchStatus }

    func record(_ call: Call) { calls.append(call) }
    var recorded: [Call] { calls }

    nonisolated func perform(
      method: String, url: String, headers: [String: String], body: Data?
    ) async throws -> (status: UInt, body: Data) {
      await record(
        Call(
          method: method,
          url: url,
          body: body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        ))
      if url.contains("/rulesets") && method == "POST" {
        return (200, Data(#"{"name":"projects/P/rulesets/abc"}"#.utf8))
      }
      if method == "PATCH" {
        return (
          patchStatus,
          Data(
            #"{"error":{"status":"NOT_FOUND","message":"Requested entity was not found."}}"#.utf8)
        )
      }
      return (200, Data("{}".utf8))
    }
  }

  private func publish(patchStatus: UInt) async throws -> [Fake.Call] {
    let fake = Fake(patchStatus: patchStatus)
    let manager = SecurityRulesManager(
      api: GoogleAPIClient(http: fake, tokens: StaticTokenProvider(value: "t")),
      projectId: "P"
    )
    try await manager.publish(kind: .firestore)
    return await fake.recorded
  }

  @Test("A project that already has a release is updated in place")
  func existingReleaseIsPatched() async throws {
    let calls = try await publish(patchStatus: 200)

    #expect(calls.contains { $0.method == "POST" && $0.url.hasSuffix("/rulesets") })
    #expect(
      calls.contains { $0.method == "PATCH" && $0.url.hasSuffix("/releases/cloud.firestore") })
    // No fallback needed, so no second write. Rule remediation runs at every push start
    // and should stay one request.
    #expect(!calls.contains { $0.method == "POST" && $0.url.hasSuffix("/releases") })
  }

  @Test("A freshly created project has its release created rather than patched")
  func missingReleaseIsCreated() async throws {
    // A new project has never had rules, so `cloud.firestore` does not exist and PATCH
    // answers 404. Assuming otherwise is what failed guided setup at the last step.
    let calls = try await publish(patchStatus: 404)

    let create = try #require(calls.last { $0.method == "POST" && $0.url.hasSuffix("/releases") })
    // `JSONSerialization` escapes forward slashes. Valid JSON, and Google accepts it, but
    // it means the raw body cannot be substring-matched against an unescaped path.
    let body = create.body.replacingOccurrences(of: "\\/", with: "/")
    #expect(body.contains("projects/P/releases/cloud.firestore"))
    #expect(body.contains("projects/P/rulesets/abc"))
    // `projects.releases.create` takes the bare Release. Sending the PATCH's wrapper is
    // accepted and releases nothing, leaving the project on Firebase's default rules.
    #expect(!body.contains("\"release\""))
  }
}

/// The published rules follow the "Allow clients to restart this server" setting.
///
/// Without this the switch only stopped the server POLLING the commands document, while
/// leaving that document world-writable in Firebase — the open channel is the whole reason
/// the switch exists, so turning the feature off has to close it where it actually lives.
/// It also made "Check Security Rules" report "nothing needed changing" whichever way the
/// switch was set, which is what made the switch look inert.
@Suite("Rules follow the remote-restart setting")
struct RemoteRestartRulesTests {

  @Test("With restart enabled, the commands document stays writable")
  func enabledKeepsChannelOpen() {
    let rules = SecurityRuleset.firestore(remoteRestartEnabled: true)
    #expect(rules.contains("/server/commands"))
    #expect(rules.contains("allow write: if true"))
    // And that is not considered a problem to fix.
    #expect(!SecurityRuleset.isPermissive(rules, kind: .firestore, remoteRestartEnabled: true))
  }

  @Test("With restart disabled, the commands document is denied outright")
  func disabledClosesChannel() {
    let rules = SecurityRuleset.firestore(remoteRestartEnabled: false)
    #expect(rules.contains("match /server/commands { allow read, write: if false; }"))
    #expect(!rules.contains("allow write: if true"))
    // The server's own address is still readable — clients need it, and that is
    // unrelated to the restart channel.
    #expect(rules.contains("match /server/config   { allow read: if true;"))
  }

  @Test("A live ruleset left open is flagged once restart is switched off")
  func openChannelIsFlaggedWhenDisabled() {
    // The exact situation the user hits: rules published while restart was on, then the
    // switch turned off. The check has to notice, or the channel stays open forever.
    let published = SecurityRuleset.firestore(remoteRestartEnabled: true)
    #expect(SecurityRuleset.isPermissive(published, kind: .firestore, remoteRestartEnabled: false))
  }

  @Test("The locked-down ruleset satisfies its own check when restart is off")
  func closedChannelIsNotFlagged() {
    let closed = SecurityRuleset.firestore(remoteRestartEnabled: false)
    #expect(!SecurityRuleset.isPermissive(closed, kind: .firestore, remoteRestartEnabled: false))
  }

  @Test("Realtime rules follow the setting too")
  func realtimeFollowsTheSetting() {
    let open = SecurityRuleset.realtimeDatabase(remoteRestartEnabled: true)
    let closed = SecurityRuleset.realtimeDatabase(remoteRestartEnabled: false)

    #expect(open.contains("\"nextRestart\": { \".read\": false, \".write\": true }"))
    #expect(closed.contains("\"nextRestart\": { \".read\": false, \".write\": false }"))

    #expect(SecurityRuleset.isPermissive(open, kind: .realtime, remoteRestartEnabled: false))
    #expect(!SecurityRuleset.isPermissive(closed, kind: .realtime, remoteRestartEnabled: false))
    // Still fine while the feature is on.
    #expect(!SecurityRuleset.isPermissive(open, kind: .realtime, remoteRestartEnabled: true))
  }
}
