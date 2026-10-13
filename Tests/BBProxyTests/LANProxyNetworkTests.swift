//  LANProxyNetworkTests
//  A LAN address follows the network it was read from.
//
//  It was resolved once, at connect, and never again, so a new DHCP lease or a move to another
//  network left clients sent to an IP this Mac no longer had, while the server reported itself
//  connected. Publishing an UNCHANGED address is the other failure: every publish pushes
//  `new-server` to every client.
//
//  Addresses are from the documentation range (RFC 5737). NO REAL ADDRESSES; see
//  CONTRIBUTING.md.

import BBCore
import Testing

@testable import BBProxy

@Suite("LAN address on a network change")
struct LANProxyNetworkTests {

  /// The address the resolver answers with, changed by the test.
  private final class Resolver: Sendable {
    private let current = Locked<String?>("192.0.2.10")
    func set(_ address: String?) { current.withLock { $0 = address } }
    func resolve() -> String? { current.withLock { $0 } }
  }

  private actor Published {
    private(set) var addresses: [String] = []
    func record(_ address: String) { addresses.append(address) }
  }

  private func connectedProxy(_ resolver: Resolver, publishing published: Published) async throws
    -> LANProxy
  {
    let proxy = LANProxy(port: 1234, addressResolver: { resolver.resolve() })
    await proxy.observe(ProxyObserver(addressChanged: { await published.record($0) }))
    _ = try await proxy.connect()
    return proxy
  }

  @Test("A new address is published when the network moves")
  func movedAddressIsPublished() async throws {
    let resolver = Resolver()
    let published = Published()
    let proxy = try await connectedProxy(resolver, publishing: published)

    resolver.set("192.0.2.20")
    await proxy.networkChanged()

    #expect(await published.addresses == ["http://192.0.2.20:1234"])
    #expect(await proxy.currentAddress == "http://192.0.2.20:1234")
  }

  @Test("An unchanged address is not published again")
  func unchangedAddressIsQuiet() async throws {
    let published = Published()
    let proxy = try await connectedProxy(Resolver(), publishing: published)

    await proxy.networkChanged()

    #expect(await published.addresses.isEmpty)
  }

  @Test("No address now keeps the last one rather than reporting a loss")
  func noAddressKeepsTheLastOne() async throws {
    let resolver = Resolver()
    let published = Published()
    let proxy = try await connectedProxy(resolver, publishing: published)

    resolver.set(nil)
    await proxy.networkChanged()

    #expect(await published.addresses.isEmpty)
    #expect(await proxy.currentAddress == "http://192.0.2.10:1234")
  }

  @Test("A proxy that is not connected publishes nothing")
  func disconnectedIsQuiet() async throws {
    let resolver = Resolver()
    let published = Published()
    let proxy = try await connectedProxy(resolver, publishing: published)
    await proxy.disconnect()

    resolver.set("192.0.2.20")
    await proxy.networkChanged()

    #expect(await published.addresses.isEmpty)
  }
}
