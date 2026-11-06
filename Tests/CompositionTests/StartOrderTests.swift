//  StartOrderTests
//  The shipped service graph starts the Private API after everything that does not need it.
//
//  Services start one at a time, and the Private API's start relaunches Messages and waits for
//  the helper, bounded at three minutes. In plain identifier order it came before the socket,
//  every tunnel and every event sink, so a slow relaunch left the server listening on a port no
//  client could reach, with no heartbeats on the sockets that did connect. `StartPriority.late`
//  on the service is the fix; this pins that the REAL graph honours it, since the unit test in
//  `BBServiceKitTests` proves the registry and not the manifests.

import BBBuiltIns
import BBServiceKit
import Testing

@testable import BlueBubblesServerCore

@Suite("Start order")
struct StartOrderTests {

  @Test("Only services that need the Private API start after it")
  func privateAPIStartsAfterEverythingIndependentOfIt() async throws {
    let context = try await AppContextFixture.make()
    let registry = ServiceRegistry<AppContext>(host: context)
    await ServerComposition.registerServices(in: registry)

    let order = try await registry.resolveStartOrder()
    let privateAPI = try #require(order.firstIndex(of: BuiltInManifests.ID.privateAPI))

    // What needs it, transitively, from the manifests the registry actually holds.
    let manifests = await registry.manifests
    var needsPrivateAPI: Set<ServiceIdentifier> = [BuiltInManifests.ID.privateAPI]
    var grew = true
    while grew {
      grew = false
      for manifest in manifests
      where !needsPrivateAPI.contains(manifest.id)
        && manifest.dependencies.contains(where: needsPrivateAPI.contains)
      {
        needsPrivateAPI.insert(manifest.id)
        grew = true
      }
    }
    #expect(needsPrivateAPI.contains(BuiltInManifests.ID.scheduledMessages))

    for (index, id) in order.enumerated() where id != BuiltInManifests.ID.privateAPI {
      if needsPrivateAPI.contains(id) {
        #expect(
          index > privateAPI, "\(id.rawValue) depends on the Private API and starts before it")
      } else {
        #expect(
          index < privateAPI, "\(id.rawValue) does not need the Private API and waits for it")
      }
    }
    // The ones that were waiting, named: the socket, every tunnel, every sink.
    typealias ID = BuiltInManifests.ID
    for id in [ID.socket, ID.push, ID.webhooks, ID.ntfy, ID.proxyCloudflare, ID.proxyLAN] {
      let index = try #require(order.firstIndex(of: id))
      #expect(index < privateAPI)
    }
  }

  /// The listener accepts Engine.IO sessions from the moment the HTTP API is up, and only the
  /// socket service heartbeats them. Anything between the two is a window in which a client
  /// connects, hears nothing, and gives up after `pingInterval + pingTimeout`.
  @Test("The socket starts straight after the HTTP API")
  func socketFollowsHTTP() async throws {
    let context = try await AppContextFixture.make()
    let registry = ServiceRegistry<AppContext>(host: context)
    await ServerComposition.registerServices(in: registry)

    let order = try await registry.resolveStartOrder()
    let http = try #require(order.firstIndex(of: BuiltInManifests.ID.http))
    let socket = try #require(order.firstIndex(of: BuiltInManifests.ID.socket))
    #expect(socket == http + 1, "services between them: \(order[(http + 1)..<socket])")
  }
}
