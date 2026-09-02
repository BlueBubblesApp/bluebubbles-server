//  HandlerCapabilityTests
//  That a controller can be registered against only what it declares it needs.
//
//  This suite is the point of `HandlerCapabilities`. A handler group that takes the whole
//  `AppContext` can only be exercised by opening two databases and building a codec
//  negotiator, a token auth service, a service registry and a Private API client — which is
//  how such groups end up with no test of their own. Each group takes a composition of small
//  protocols instead, and the fakes below are what that buys: a struct with one or two
//  members.
//
//  The second thing it guards is the handler IDs. `buildRouter` refuses to mount a route
//  whose handler is unregistered, but with nothing exercising that in tests a mistyped ID is
//  caught at server start-up and nowhere else. Diffing the registered IDs against the route
//  table's is that check.

import BBAuth
import BBHTTPAPI
import BBIMessage
import BBPersistence
import BBSerialization
import BBSettings
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Handler capabilities")
struct HandlerCapabilityTests {

  // MARK: - Fakes
  //
  // Each is exactly what one handler group asked for, and nothing else. That they are this
  // small is the result being asserted.

  private struct ScheduleHost: ScheduleProviding {
    let schedule: ScheduleInterface
  }

  private struct SecurityHost: AccessControlProviding {
    let accessControl: AccessControlService
  }

  private struct AuthHost: TokenAuthProviding {
    let tokenAuth: TokenAuthService
  }

  /// Returns no interfaces at all, which is itself the contract: with chat.db absent the
  /// routes must refuse with a clear 503 rather than fail obscurely. There is deliberately
  /// no capability here vending a raw repository: every handler goes through the interfaces
  /// layer, which removes the door rather than leaving it unused.
  private struct NoInterfacesHost: InterfaceProviding {
    func interfaces() async -> ServerInterfaces? { nil }
    func requireInterfaces() async throws -> ServerInterfaces {
      throw InterfaceError.unavailable("the iMessage database is not readable")
    }
  }

  private struct SettingsHost: SettingsProviding {
    let settings: SettingsStore
  }

  // MARK: - Registration

  @Test("A handler group registers against only the capabilities it declares")
  func schedulingNeedsOnlyItsOwnInterface() throws {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    var registry = HandlerRegistry()

    // One value, over one database. No AppContext, no service registry, no chat.db.
    ScheduleHandlers.register(
      into: &registry,
      context: ScheduleHost(schedule: ScheduleInterface(database: database))
    )

    for id: HandlerID in [.scheduleList, .scheduleFind, .scheduleCreate, .scheduleUpdate] {
      #expect(registry.handler(for: id) != nil, "\(id.rawValue) was not registered")
    }
  }

  @Test("Access control, token auth and hydration each need one thing")
  func othersAreEquallyNarrow() async throws {
    var registry = HandlerRegistry()

    SecurityHandlers.register(into: &registry, context: SecurityHost(accessControl: .init()))
    AuthHandlers.register(into: &registry, context: AuthHost(tokenAuth: TokenAuthService()))
    HydrationHandlers.register(into: &registry, context: NoInterfacesHost())

    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let settings = try await SettingsStore(
      database: database, secrets: InMemorySecretStore()
    )
    LandingHandlers.register(into: &registry, context: SettingsHost(settings: settings))

    #expect(registry.handler(for: .securityListBlocked) != nil)
    #expect(registry.handler(for: .messageHydrate) != nil)
    #expect(registry.handler(for: .uiIndex) != nil)
  }

  // MARK: - The route table agrees

  @Test("Every schedule route in the table has a handler behind it")
  func scheduleRoutesAreAllCovered() throws {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    var registry = HandlerRegistry()
    ScheduleHandlers.register(
      into: &registry,
      context: ScheduleHost(schedule: ScheduleInterface(database: database))
    )

    // The group as the router will mount it. `missing(for:)` is what `buildRouter` consults
    // before refusing to start, so this is the same question asked earlier.
    let scheduleGroups = RouteTable.groups.filter { group in
      group.routes.contains { $0.handlerID.rawValue.hasPrefix("schedule.") }
    }
    let missing = registry.missing(for: scheduleGroups)
      .filter { $0.rawValue.hasPrefix("schedule.") }

    #expect(missing.isEmpty, "unregistered: \(missing.map(\.rawValue).joined(separator: ", "))")
  }
}
