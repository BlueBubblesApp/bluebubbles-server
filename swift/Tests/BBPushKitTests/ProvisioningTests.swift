//  ProvisioningTests
//  The provisioning sequence, against a scripted Google.
//
//  This code was written in Phase 6, tested by nothing, and referenced by nothing — so it had
//  never run in any form. Wiring it up in Phase 13 is what made its correctness matter, and
//  the first thing that surfaced was a defect no unit test existed to catch: every
//  long-running operation was polled against Cloud Resource Manager, whatever service had
//  issued it. Google's operations live on the host that created them, so enabling the APIs —
//  the second step of eight — would 404 on every poll and then time out three minutes later
//  complaining about the wrong thing.
//
//  The fake here answers by URL, which is the point: the assertions are about WHERE each
//  request went, and a mock that ignored the URL could not have caught this.
//
//  See `docs/EVENTS.md`.

import BBSettings
import Foundation
import Testing

@testable import BBPushKit

@Suite("Firebase provisioning")
struct ProvisioningTests {

  /// Records every request and answers from a table keyed on a URL substring.
  ///
  /// First match wins, so the table reads top-to-bottom as "the specific cases, then the
  /// general one". Anything unmatched answers `{}`, which every step here treats as an
  /// operation that finished inline.
  private struct ScriptedGoogle: HTTPPerforming {
    let responses: [(match: String, body: String)]
    let recorder: Recorder

    func perform(
      method: String, url: String, headers: [String: String], body: Data?
    ) async throws -> (status: UInt, body: Data) {
      await recorder.record(method: method, url: url)
      for entry in responses where url.contains(entry.match) {
        return (200, Data(entry.body.utf8))
      }
      return (200, Data("{}".utf8))
    }
  }

  private actor Recorder {
    private(set) var requests: [(method: String, url: String)] = []
    func record(method: String, url: String) { requests.append((method, url)) }
    func urls(method: String) -> [String] {
      requests.filter { $0.method == method }.map(\.url)
    }
  }

  /// A service-account key file, base64'd the way `iam.googleapis.com` returns it.
  static var serviceAccountKeyResponse: String {
    // `private_key` has to look like a PEM: `ServiceAccount.parse` checks it at import
    // time rather than at first send, because a wrong file otherwise produces an
    // authentication failure hours later with nothing pointing at the cause.
    let account = """
      {"type":"service_account","project_id":"P","private_key_id":"k",
       "private_key":"-----BEGIN PRIVATE KEY-----\\nx\\n-----END PRIVATE KEY-----\\n",
       "client_email":"e@x.iam.gserviceaccount.com",
       "client_id":"1","token_uri":"https://oauth2.googleapis.com/token"}
      """
    return #"{"privateKeyData":"\#(Data(account.utf8).base64EncodedString())"}"#
  }

  /// The account list `iam.googleapis.com` returns.
  ///
  /// The email carries a SUFFIX, because every real one does — `-fbsvc` on projects created
  /// recently, five random characters before that. The provisioner used to construct a
  /// plain `firebase-adminsdk@{project}` address, which matches no project Google has ever
  /// created, so this fixture is what makes that difference observable.
  static let serviceAccountsListResponse = """
    {"accounts":[
      {"name":"projects/P/serviceAccounts/firebase-adminsdk-fbsvc@P.iam.gserviceaccount.com",
       "email":"firebase-adminsdk-fbsvc@P.iam.gserviceaccount.com",
       "uniqueId":"114812345678901234567",
       "displayName":"firebase-adminsdk"},
      {"name":"projects/P/serviceAccounts/P@appspot.gserviceaccount.com",
       "email":"P@appspot.gserviceaccount.com",
       "uniqueId":"11499999999999999999",
       "displayName":"App Engine default service account"}
    ]}
    """

  /// A REALISTIC `google-services.json`.
  ///
  /// This fixture used to carry `project_info` and nothing else — which is precisely the
  /// shape the storage defect produced, so no test built on it could ever have caught the
  /// document being truncated. The `client` array is the part clients cannot work without.
  static var clientConfigResponse: String {
    return #"{"configFileContents":"\#(Data(clientConfigJSON.utf8).base64EncodedString())"}"#
  }

  static let clientConfigJSON = """
    {"project_info":{"project_number":"123","project_id":"P"},
     "client":[{"client_info":{"mobilesdk_app_id":"1:123:android:abcdef",
       "android_client_info":{"package_name":"com.bluebubbles.messaging"}},
      "api_key":[{"current_key":"AIzaSyTESTKEY"}],
      "services":{"appinvite_service":{"other_platform_oauth_client":[]}}}],
     "configuration_version":"1"}
    """

  private func run() async throws -> Recorder {
    let recorder = Recorder()
    let google = ScriptedGoogle(
      responses: [
        // Every creation call answers with an operation that is already done, so the
        // run reaches the end without sleeping through real polls. `awaitOperation`
        // returning early is not what is under test here — WHERE it would poll is,
        // and the enable step below deliberately returns a pending one.
        (
          match: "serviceusage.googleapis.com/v1/projects",
          body: #"{"name":"operations/enable-1"}"#
        ),
        (
          match: ":addFirebase",
          body: #"{"name":"operations/firebase-1"}"#
        ),
        // Ordered before `/androidApps`: the config URL is
        // `…/androidApps/1:2:3/config` and contains both, so the broader pattern
        // would answer it with an app registration.
        (match: "/config", body: Self.clientConfigResponse),
        // Registering the app is a real long-running operation, so this is scripted
        // the way Google actually answers: a pending operation whose resolution
        // carries the app resource name.
        (
          match: "operations/android-1",
          body: #"{"done":true,"response":{"name":"projects/P/androidApps/1:2:3"}}"#
        ),
        (match: "/androidApps", body: #"{"name":"operations/android-1"}"#),
        (match: "operations/", body: #"{"done":true,"name":"operations/x"}"#),
        (match: "/keys", body: Self.serviceAccountKeyResponse),
        (match: "/serviceAccounts", body: Self.serviceAccountsListResponse),
        (match: "/rulesets", body: #"{"name":"projects/P/rulesets/r1"}"#),
        (match: "cloudresourcemanager", body: #"{"done":true}"#),
      ],
      recorder: recorder
    )

    let provisioner = FirebaseProvisioner(
      api: GoogleAPIClient(http: google, tokens: StaticTokenProvider(value: "user-token"))
    )
    _ = try await provisioner.provision()
    return recorder
  }

  @Test("The Admin SDK account is discovered by listing, never by constructing an address")
  func serviceAccountIsDiscoveredNotGuessed() async throws {
    // THE defect behind every failed guided setup. The provisioner constructed
    // `firebase-adminsdk@{project}.iam.gserviceaccount.com`, but Google always appends a
    // suffix — `-fbsvc` now, five random characters historically — so that address exists
    // for no project at all. Every run 404'd twelve times over sixty seconds and reported
    // the account as "not ready yet", which read as slowness rather than as a bug.
    let recorder = try await run()
    let posts = await recorder.urls(method: "POST")
    let gets = await recorder.urls(method: "GET")

    // The list is fetched...
    #expect(
      gets.contains {
        $0.hasSuffix("iam.googleapis.com/v1/projects/") == false
          && $0.contains("/serviceAccounts")
          && !$0.contains("/keys")
      })

    // ...and the key is minted against the identifier it returned.
    let keyRequests = posts.filter { $0.hasSuffix("/keys") }
    #expect(keyRequests.count == 1)
    #expect(keyRequests.first?.contains("114812345678901234567") == true)

    // The constructed address must appear NOWHERE. Asserted negatively because the bug
    // was not a wrong call — it was a plausible-looking one.
    #expect(!posts.contains { $0.contains("firebase-adminsdk@") })
  }

  @Test("The required APIs are enabled in a single batch call")
  func apisAreEnabledInOneBatch() async throws {
    // Five services, each with its own POST and its own polling loop, was 26 seconds of a
    // 105-second run. `:batchEnable` takes the whole list at once.
    let recorder = try await run()
    let posts = await recorder.urls(method: "POST")

    #expect(posts.filter { $0.contains(":batchEnable") }.count == 1)
    #expect(!posts.contains { $0.contains(":enable") && !$0.contains(":batchEnable") })
  }

  @Test("IAM is among the enabled APIs, and Identity Toolkit is not")
  func enablesIAMRatherThanIdentityToolkit() {
    // Minting the Admin SDK key is an IAM call, so omitting `iam.googleapis.com` breaks
    // the step the whole flow exists to reach. It was omitted: the reference enables it
    // in a method named `enableIdentityApi`, and the port read that as Identity Toolkit —
    // Firebase Auth, which this server never uses.
    #expect(FirebaseProvisioner.requiredServices.contains("iam.googleapis.com"))
    #expect(!FirebaseProvisioner.requiredServices.contains("identitytoolkit.googleapis.com"))
  }

  @Test("Provisioning returns both documents whole, not projections of them")
  func provisioningPreservesTheWholeClientConfig() async throws {
    // The guided path fetched Google's `google-services.json`, decoded it straight into
    // `FirebaseClientConfig` — a three-field model of what the SERVER needs — and kept
    // only that. The Android API key and app ID were discarded at the one moment they
    // existed, so a project created by this flow produced a client configuration no
    // client could use, exactly like the import path did from the other direction.
    let recorder = Recorder()
    let google = ScriptedGoogle(
      responses: [
        (match: "serviceusage", body: #"{"done":true}"#),
        (match: "/config", body: Self.clientConfigResponse),
        (match: "/androidApps", body: #"{"name":"projects/P/androidApps/1:2:3"}"#),
        (match: "/keys", body: Self.serviceAccountKeyResponse),
        (match: "/serviceAccounts", body: Self.serviceAccountsListResponse),
        (match: "/rulesets", body: #"{"name":"projects/P/rulesets/r1"}"#),
        (match: "cloudresourcemanager", body: #"{"done":true}"#),
      ],
      recorder: recorder
    )

    let result = try await FirebaseProvisioner(
      api: GoogleAPIClient(http: google, tokens: StaticTokenProvider(value: "t"))
    ).provision()

    let clientText = String(decoding: result.clientConfigJSON, as: UTF8.self)
    #expect(clientText.contains("AIzaSyTESTKEY"))
    #expect(clientText.contains("mobilesdk_app_id"))
    #expect(clientText.contains("configuration_version"))

    // And the service-account document keeps the fields the projection does not model,
    // so the stored credential stays byte-faithful to what Google issued.
    let accountText = String(decoding: result.serviceAccountJSON, as: UTF8.self)
    #expect(accountText.contains("client_id"))
    #expect(result.serviceAccount.projectId == "P")
    #expect(result.clientConfig.projectNumber == "123")
  }

  @Test("Each long-running operation is polled on the service that issued it")
  func operationsArePolledOnTheirOwnHost() async throws {
    let recorder = try await run()
    let polls = await recorder.urls(method: "GET").filter { $0.contains("operations/") }

    // The defect: these were all sent to Cloud Resource Manager. Enabling five APIs is the
    // second step of eight, so provisioning could never have got past it.
    #expect(
      polls.contains { $0.hasPrefix("https://serviceusage.googleapis.com/v1/operations/enable-1") })
    #expect(
      polls.contains {
        $0.hasPrefix("https://firebase.googleapis.com/v1beta1/operations/firebase-1")
      })
    #expect(
      !polls.contains { $0.contains("cloudresourcemanager") && $0.contains("enable-1") },
      "a Service Usage operation was polled against Cloud Resource Manager"
    )
  }

  @Test("An already-enabled API is not polled at all")
  func doneOperationSentinelIsNotPolled() async throws {
    // Service Usage answers an API that is already on with a `DONE_OPERATION` sentinel
    // rather than a real operation name. Polling it returns a 404 that reads like a
    // failure — on the re-run of a flow that is explicitly meant to be re-runnable.
    let recorder = Recorder()
    let google = ScriptedGoogle(
      responses: [
        (
          match: "serviceusage.googleapis.com/v1/projects",
          body: #"{"name":"operations/noop.DONE_OPERATION"}"#
        ),
        (match: "/keys", body: Self.serviceAccountKeyResponse),
        (match: "/serviceAccounts", body: Self.serviceAccountsListResponse),
        (match: "/config", body: Self.clientConfigResponse),
        // The INLINE-done form: Google answers with the created app rather than an
        // operation, so nothing is ever polled and the name is only in this response.
        (match: "/androidApps", body: #"{"name":"projects/P/androidApps/1:2:3"}"#),
        (match: "/rulesets", body: #"{"name":"projects/P/rulesets/r1"}"#),
      ],
      recorder: recorder
    )
    _ = try await FirebaseProvisioner(
      api: GoogleAPIClient(http: google, tokens: StaticTokenProvider(value: "t"))
    ).provision()

    let polls = await recorder.urls(method: "GET")
    #expect(!polls.contains { $0.contains("DONE_OPERATION") })
  }

  @Test("New projects get a full-length, random identifier")
  func projectIdentifierEntropy() async throws {
    // Vulnerability #3: `bluebubbles-[4 hex]` is 65,536 possibilities, enumerable in
    // minutes. Asserted through the actual provisioning call rather than against the
    // generator alone, so that swapping the generator out would fail here too.
    let recorder = try await run()
    let creates = await recorder.urls(method: "POST")
      .filter { $0.hasSuffix("cloudresourcemanager.googleapis.com/v3/projects") }
    #expect(creates.count == 1)
    #expect(ProjectIdentifier.entropyBits() >= 64)
  }

  @Test("Security rules are published before the project is announced anywhere")
  func rulesArePublishedDuringProvisioning() async throws {
    // The current flow publishes world-writable rules at creation and tightens them
    // never. A new project must never be permissive, even briefly — there is no window
    // here in which it is.
    let recorder = try await run()
    let posts = await recorder.urls(method: "POST")
    #expect(posts.contains { $0.contains("firebaserules.googleapis.com") })
  }
}

/// Starting push against a project that may or may not still exist.
///
/// The reference server checks this and throws on ANY failure, stopping the service — so an
/// install behind a flaky connection loses push at startup over a transient error. The
/// distinction asserted here is that only a project Google states is GONE discards
/// credentials; everything else leaves push running.
@Suite("Firebase project validation")
struct ProjectValidationTests {

  private struct FixedResponse: HTTPPerforming {
    let status: UInt
    let body: String

    func perform(
      method: String, url: String, headers: [String: String], body: Data?
    ) async throws -> (status: UInt, body: Data) {
      // Only the project lookup is scripted; a token mint has to succeed for the
      // lookup to be reached at all.
      if url.contains("oauth2.googleapis.com/token") {
        return (200, Data(#"{"access_token":"t","expires_in":3600}"#.utf8))
      }
      return (self.status, Data(self.body.utf8))
    }
  }

  /// A throwaway 2048-bit RSA key, generated for this file and used nowhere else.
  ///
  /// It has to be a REAL key: the project lookup is an authenticated call, so the assertion
  /// about how a lookup failure is handled is only reached once the JWT actually signs. A
  /// placeholder key fails at the mint instead, and the test then passes for the wrong
  /// reason — it did on the first run of this suite.
  private static let privateKey =
    "-----BEGIN PRIVATE KEY-----\\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC9ziOBVGrjHM4p\\nbqAbSVLfw67Fv6TIleyFgM2EN4IMXKCMi9f8wfOFcVbl6ZXBBvt8/J+sdvq0ibBP\\nbBs21bzzOgyNJdlgDVGel9yesmnyxHG5Vr1sqJ4OGvSZw3xz2X31yJVgrKUR4VmI\\nGWie6gMpuFkCERsr9QnpNKEXJfwKOpAD3EENxVP2IJnHaM4CMz1gShTEqvu5ipE9\\nSTsuxcyVxICPqZTInwmfu+U1Te6M+42CPo7bm9BY+Vc68ezowbi262EAeYDrPAky\\n52G40fGq4DpYpxpuQKLvPi81oFElkXAsklD0QAYPv1oJ37MOkoG2n9rj9AxL6yXA\\nW0+GfLBLAgMBAAECggEAAi8G9Yv1FtvT+2IMcYPsciqcLiZATRZ8fCS5OJYy5tWB\\n+1v4hi3tEVH2f/qqAGiGKC/33lIYHE+hOaiyv3TCEcJPNqiC0boVgE+a+DBxS5u6\\n+zjmQQPHnb3tpn87RVHxQwylu1EBLS18jDZOn9VtZ+N5Eq8DswPEs2wplkyXk76H\\nqKDeqFUMHDqY43CbczN8gbU3gSfSMyJ+t3vQhJgvY59UaFZl9RPRuIw5P0mmHVQE\\niFi+QWgS0k8pqFLU3LKfNr/pGc/z7PfPA3AkYkIvCoK0nVLA92OuoNzlLrynv7k0\\nc+ld+uZVn1KfEDMjwaMRRvJYo9dCuY7d3l7StD8iwQKBgQDqoUPda0ETx4j24jLW\\nm6Gjy0p1VFwtlUTdyZ7YbVt2BK6ghHmu3BoreDyu7iDL1gFCkyF0XOTQrY1TTM/a\\ncAcEY0euT0J606UKp0AIVAgVoQIgNpxyd6JvHCWweHnPc77RmycdaJkH8IthnHKG\\nEtMEbWUMp65QBrUL2FCkKnaB+wKBgQDPF7iL+C0uxcd4Glj5gLvMyLMoerj0hdGi\\ne6I8lxNtCmP0hy3CyqSDCaNFYgirjNT+FAcra5cBk6kkBQ36L5FQCpmQJ7Cpbesz\\nxE0Yv5Z9amDGmcSduqROzSVhqjE01Xz/+LHb26w/bTXgYdBUyIo2qRpaDiGN0Tu6\\na4qk4oeJ8QKBgFr2qpjtPA2vDiqpB4ysSb520icqzZHejRRvVmYR/6OBrTIOKh7g\\ntkSkGOK4734XOeXVpOK4IP3GS0RAQ1UsmYvZ8bBiiiOUaif3L5wK+BdqlKhog77d\\nItxwzSvdiVwkQ5Z/0GpWYv3xBBiTztKr+aN9xe9iEvJzpz0wYBNFYyyBAoGANJJk\\nAfxdk/sXWRDvN1+LzT/B42vMGh8Cicny9IixoMO7fi722fVRcAZ5UTrC0rHsvBdf\\nfpFQg1D15jP2SWXb8MLQGv1IZqqFw914aOjyDiJ8MM6GUDg6T9raO4HV/gCYO+7p\\nT9PjVTKnM7ABEBTcqWWiT+w4bmUIUZnNV3A+UjECgYEAz+vltim36OpaPygsyjUr\\nymCPeAFOjeKg2XIKjN2GSJo0ss0+pPKEyHV8MBY8v08YzWYkczh6u/gvCbdj+pRW\\nwE06LHjg8map77wwFsGqhkXU0qpK+THakT9vUn9LEEjvGrq1epjX6U/xAGqUPRl/\\niTPBh3KPSmDqu3zxrRuCkvI=\\n-----END PRIVATE KEY-----\\n"

  private static var serviceAccount: String {
    """
    {"type":"service_account","project_id":"gone-project","private_key_id":"k",
     "private_key":"\(privateKey)",
     "client_email":"e@x.iam.gserviceaccount.com",
     "token_uri":"https://oauth2.googleapis.com/token"}
    """
  }

  private func store() async throws -> PushCredentialStore {
    let store = PushCredentialStore(secrets: InMemorySecretStore())
    _ = try await store.importServiceAccount(Data(Self.serviceAccount.utf8))
    return store
  }

  @Test("A deleted project discards its credentials and reports itself unconfigured")
  func deletedProjectIsUnloaded() async throws {
    let credentials = try await store()
    let service = PushService(
      credentials: credentials,
      http: FixedResponse(
        status: 404,
        body: #"{"error":{"status":"NOT_FOUND","message":"project has been deleted"}}"#
      )
    )

    await service.start()

    #expect(await service.isConfigured == false)
    // Discarded, not merely ignored: they can never work again, and keeping them means
    // the UI reporting push as set up forever on a server that cannot send anything.
    #expect(try await credentials.serviceAccount() == nil)
  }

  @Test("A transient failure to reach Google leaves push running")
  func transientFailureDoesNotUnloadCredentials() async throws {
    // The reference implementation's behaviour is the bug being avoided here: it throws
    // on any error from this check and stops the service, so a captive portal or a 503
    // takes push down at startup. A project that cannot be REACHED is not a project that
    // does not exist.
    let credentials = try await store()
    let service = PushService(
      credentials: credentials,
      http: FixedResponse(status: 503, body: #"{"error":{"message":"backend error"}}"#)
    )

    await service.start()

    #expect(await service.isConfigured)
    #expect(try await credentials.serviceAccount() != nil)
  }

  @Test("A permission error on the check does not unload credentials either")
  func missingPermissionDoesNotUnloadCredentials() async throws {
    // A service account without `firebase.projects.get` cannot answer this question and
    // sends notifications perfectly well regardless.
    let credentials = try await store()
    let service = PushService(
      credentials: credentials,
      http: FixedResponse(
        status: 403,
        body: #"{"error":{"status":"PERMISSION_DENIED","message":"missing permission"}}"#
      )
    )

    await service.start()

    #expect(await service.isConfigured)
    #expect(try await credentials.serviceAccount() != nil)
  }
}

/// Adopting a project that already exists, rather than creating another one.
///
/// FCM registration tokens are scoped to a Firebase project, so creating a new project
/// silently invalidates every client registered against the old one. Adoption is therefore
/// the preferred path, not merely the faster one.
@Suite("Adopting an existing project")
struct ProjectAdoptionTests {

  private actor Recorder {
    private(set) var requests: [(method: String, url: String)] = []
    func record(method: String, url: String) { requests.append((method, url)) }
    func urls(method: String) -> [String] {
      requests.filter { $0.method == method }.map(\.url)
    }
    var all: [(method: String, url: String)] { requests }
  }

  private struct Google: HTTPPerforming {
    let recorder: Recorder
    /// Keys already on the account, as `keys.list` would report them.
    let existingKeys: Int

    func perform(
      method: String, url: String, headers: [String: String], body: Data?
    ) async throws -> (status: UInt, body: Data) {
      await recorder.record(method: method, url: url)

      if url.contains("/androidApps") && method == "GET" && !url.contains("/config") {
        return (
          200,
          Data(
            #"{"apps":[{"name":"projects/P/androidApps/1:2:3","packageName":"com.bluebubbles.messaging"}]}"#
              .utf8)
        )
      }
      if url.contains("/config") {
        return (200, Data(ProvisioningTests.clientConfigResponse.utf8))
      }
      if url.contains("/keys") && method == "GET" {
        let keys = (0..<existingKeys)
          .map {
            #"{"name":"projects/P/serviceAccounts/A/keys/old\#($0)","keyType":"USER_MANAGED"}"#
          }
          .joined(separator: ",")
        return (200, Data("{\"keys\":[\(keys)]}".utf8))
      }
      if url.contains("/keys") && method == "POST" {
        return (200, Data(ProvisioningTests.serviceAccountKeyResponse.utf8))
      }
      if url.contains("/serviceAccounts") {
        return (200, Data(ProvisioningTests.serviceAccountsListResponse.utf8))
      }
      if url.contains("/rulesets") {
        return (200, Data(#"{"name":"projects/P/rulesets/r1"}"#.utf8))
      }
      return (200, Data(#"{"done":true}"#.utf8))
    }
  }

  private func provisioner(_ recorder: Recorder, existingKeys: Int = 0) -> FirebaseProvisioner {
    FirebaseProvisioner(
      api: GoogleAPIClient(
        http: Google(recorder: recorder, existingKeys: existingKeys),
        tokens: StaticTokenProvider(value: "t")
      )
    )
  }

  @Test("Adopting neither creates a project nor re-adds Firebase")
  func adoptionSkipsCreation() async throws {
    let recorder = Recorder()
    _ = try await provisioner(recorder).provision(adopting: "existing-project")
    let posts = await recorder.urls(method: "POST")

    #expect(!posts.contains { $0.hasSuffix("cloudresourcemanager.googleapis.com/v3/projects") })
    #expect(!posts.contains { $0.contains(":addFirebase") })
    // Still enabled: an older project may predate a service this server now needs, and
    // enabling is idempotent and costs one batched call.
    #expect(posts.contains { $0.contains(":batchEnable") })
  }

  @Test("An Android app that already exists is reused, not duplicated")
  func existingAndroidAppIsReused() async throws {
    // Registering a second app for the same package name yields a duplicate whose
    // google-services.json may not be the one clients are already using.
    let recorder = Recorder()
    _ = try await provisioner(recorder).provision(adopting: "existing-project")
    let posts = await recorder.urls(method: "POST")

    #expect(!posts.contains { $0.hasSuffix("/androidApps") })
  }

  @Test("A held key is reused without touching IAM at all")
  func heldKeyIsReused() async throws {
    // Google returns private key material only at creation, so a key already in the
    // Keychain is the only existing key that can ever be used again.
    let recorder = Recorder()
    let held = Data(
      #"""
      {"type":"service_account","project_id":"existing-project","private_key_id":"held",
       "private_key":"-----BEGIN PRIVATE KEY-----\nheld\n-----END PRIVATE KEY-----\n",
       "client_email":"held@x.iam.gserviceaccount.com"}
      """#.utf8)

    let result = try await provisioner(recorder).provision(
      adopting: "existing-project",
      existingServiceAccountJSON: held,
      keyStrategy: .reuseHeld
    )

    #expect(result.serviceAccount.privateKeyId == "held")
    let calls = await recorder.all
    #expect(!calls.contains { $0.url.contains("/keys") })
  }

  @Test("Minting leaves existing keys alone unless deletion was chosen")
  func mintingIsAdditiveByDefault() async throws {
    // The reference server always deletes user-managed keys first, which silently breaks
    // any other server using this project. Here that only happens on request.
    let recorder = Recorder()
    _ = try await provisioner(recorder, existingKeys: 3).provision(
      adopting: "existing-project",
      keyStrategy: .mintNew(deletingExisting: false)
    )

    let deletes = await recorder.urls(method: "DELETE")
    #expect(deletes.isEmpty)
  }

  @Test("Choosing deletion removes the old keys, and only after a new one exists")
  func deletionHappensAfterMinting() async throws {
    // Ordered so a failed mint cannot leave the project with no usable key at all.
    let recorder = Recorder()
    _ = try await provisioner(recorder, existingKeys: 2).provision(
      adopting: "existing-project",
      keyStrategy: .mintNew(deletingExisting: true)
    )

    let calls = await recorder.all
    let mintIndex = try #require(
      calls.firstIndex { $0.method == "POST" && $0.url.hasSuffix("/keys") })
    let deleteIndices = calls.indices.filter { calls[$0].method == "DELETE" }

    #expect(deleteIndices.count == 2)
    #expect(deleteIndices.allSatisfy { $0 > mintIndex })
  }
}

/// Detecting the one provisioning failure a user can actually fix.
@Suite("Billing requirement detection")
struct BillingDetectionTests {

  private struct Refusing: HTTPPerforming {
    let status: UInt
    let code: String
    let message: String

    func perform(
      method: String, url: String, headers: [String: String], body: Data?
    ) async throws -> (status: UInt, body: Data) {
      if url.contains("/databases") && method == "POST" {
        let envelope = #"{"error":{"code":\#(status),"status":"\#(code)","message":"\#(message)"}}"#
        return (status, Data(envelope.utf8))
      }
      if url.contains("/serviceAccounts") && !url.contains("/keys") {
        return (200, Data(ProvisioningTests.serviceAccountsListResponse.utf8))
      }
      if url.contains("/keys") {
        return (200, Data(ProvisioningTests.serviceAccountKeyResponse.utf8))
      }
      // Scripted so a run that gets PAST the database step reaches the end. Without
      // these the 409 case fails two steps later, which reads as the 409 not being
      // handled when it is.
      if url.contains("/androidApps") && !url.contains("/config") {
        return (
          200,
          Data(
            #"{"apps":[{"name":"projects/P/androidApps/1:2:3","packageName":"com.bluebubbles.messaging"}]}"#
              .utf8)
        )
      }
      if url.contains("/config") {
        return (200, Data(ProvisioningTests.clientConfigResponse.utf8))
      }
      if url.contains("/rulesets") {
        return (200, Data(#"{"name":"projects/P/rulesets/r1"}"#.utf8))
      }
      return (200, Data(#"{"done":true}"#.utf8))
    }
  }

  private func provision(status: UInt, code: String, message: String) async -> (any Error)? {
    let provisioner = FirebaseProvisioner(
      api: GoogleAPIClient(
        http: Refusing(status: status, code: code, message: message),
        tokens: StaticTokenProvider(value: "t")
      )
    )
    do {
      _ = try await provisioner.provision(adopting: "P")
      return nil
    } catch {
      return error
    }
  }

  /// Google returns this refusal under several different codes depending on the account and
  /// the API surface. The reference server keys on 403 alone, so the others surface as a
  /// raw permission error the user cannot act on.
  @Test(
    "Billing is recognised whatever code Google attaches",
    arguments: [
      (UInt(403), "PERMISSION_DENIED", "Firestore API requires billing to be enabled"),
      (UInt(400), "FAILED_PRECONDITION", "The project must have a billing account"),
      (UInt(403), "PERMISSION_DENIED", "This API requires billing enabled on the project"),
    ]
  )
  func billingIsDetected(status: UInt, code: String, message: String) async throws {
    let error = try #require(await provision(status: status, code: code, message: message))
    guard case ProvisioningError.billingRequired(let projectId) = error else {
      Issue.record("expected billingRequired, got \(error)")
      return
    }
    // Carries the project so setup can resume INTO it rather than creating another.
    #expect(projectId == "P")
  }

  @Test("A database that already exists is not a failure")
  func alreadyExistingDatabaseIsFine() async throws {
    #expect(await provision(status: 409, code: "ALREADY_EXISTS", message: "already exists") == nil)
  }

  @Test("An unrelated permission error is not reported as a billing problem")
  func unrelatedErrorIsNotBilling() async throws {
    // The detection matches on the word "billing", so it has to not fire on everything
    // else that returns 403.
    let error = try #require(
      await provision(status: 403, code: "PERMISSION_DENIED", message: "caller lacks permission")
    )
    if case ProvisioningError.billingRequired = error {
      Issue.record("an unrelated permission error was reported as a billing problem")
    }
  }
}
