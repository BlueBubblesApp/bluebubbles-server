//  ProxyManifestDispatchTests
//  Every connection method declares its own manifest, and declares the entitlement it needs.
//
//  **The bug this suite was written for is now unrepresentable, and that is worth recording
//  rather than deleting.** `ProxyServiceBase.manifest` used to be
//  `fatalError("… is abstract …")`, and reaching it took the whole app down at startup. It was
//  reachable: `scoped` is a `ContextualService` protocol-extension member, so its
//  `Self.manifest` bound STATICALLY to the type declaring the conformance — the base — rather
//  than dynamically to the subclass. Anything reading a core setting through the scope trapped.
//  "Local Network" hit it first, because it needs `socket_port` before it can publish anything,
//  which made the simplest connection method the one that crashed on launch.
//
//  `ProxyService<Method>` has no abstract member to reach and no override to forget: a method
//  that does not supply a manifest does not compile, and `ProxyHost` carries the manifest as a
//  stored property so there is no `Self` to bind to the wrong type. The dispatch assertion is
//  therefore gone — it is now a property of the type system rather than something to test.
//
//  What remains is what the type system does NOT check: that the five manifests are distinct,
//  and that each declares the entitlement its code relies on.

import BBServiceKit
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Connection method manifests")
struct ProxyManifestDispatchTests {

  /// Held as `any ProxyMethod.Type`, which is all `ProxyService` ever needs of them.
  private static let methods: [(String, any ProxyMethod.Type)] = [
    ("LAN", LANMethod.self),
    ("Custom URL", DynamicDNSMethod.self),
    ("ngrok", NgrokMethod.self),
    ("Cloudflare", CloudflareMethod.self),
    ("zrok", ZrokMethod.self),
  ]

  @Test("Every connection method declares a manifest in the right category")
  func manifestsAreWellFormed() {
    for (label, method) in Self.methods {
      let manifest = method.manifest
      #expect(!manifest.id.rawValue.isEmpty, "\(label) has an empty manifest id")
      #expect(manifest.category == .reverseProxy, "\(label) is not a connection method")
    }
  }

  @Test("Connection method identifiers are distinct")
  func identifiersAreDistinct() {
    // They are the exclusive category's keys: two methods sharing an id would make
    // `canRun` admit both, and two tunnels would race to publish `server_address`.
    let ids = Self.methods.map { $0.1.manifest.id.rawValue }
    #expect(Set(ids).count == ids.count, "duplicate manifest ids: \(ids)")
  }

  @Test("Every connection method may read the port it forwards to")
  func allDeclarePortEntitlement() {
    // `ProxyHost.forwardedPort()` reads `socket_port` through the scope, which only succeeds
    // if the manifest asked for it. A method missing this reads the default 1234 no matter
    // what the user set, and publishes an address nothing is listening on.
    for (label, method) in Self.methods {
      let reads = method.manifest.entitlements.contains { entitlement in
        if case .readSettings(let keys) = entitlement { return keys.contains("socket_port") }
        return false
      }
      #expect(reads, "\(label) cannot read socket_port")
    }
  }

  /// The registry keys on `Service.id`, which comes from the manifest. Each specialisation of
  /// the generic is a distinct type, so this is what confirms the five register separately
  /// rather than collapsing onto one.
  @Test("Each specialisation carries its own service id")
  func specialisationsAreDistinctServices() {
    let ids = [
      ProxyService<LANMethod>.id, ProxyService<DynamicDNSMethod>.id,
      ProxyService<NgrokMethod>.id, ProxyService<CloudflareMethod>.id,
      ProxyService<ZrokMethod>.id,
    ]
    #expect(Set(ids).count == 5)
  }
}
