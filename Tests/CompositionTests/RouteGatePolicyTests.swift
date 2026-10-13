//  RouteGatePolicyTests
//  A route behind a switch says so in the route table, and no handler checks one itself.
//
//  Fourteen FaceTime handlers each opened with the same setting check, and the Send Later
//  gate existed in three versions and on none of cancel, edit or send-now. Both now come from
//  `requiring:` on the route, evaluated by `RouteGates` before the handler runs. These hold
//  the two halves of that: the declarations, route by route, and a scan of `BBHandlers` for
//  a handler that checks a switch for itself again.

import BBTestSupport
import Testing

@testable import BBHTTPAPI
@testable import BBHandlers

@Suite("Route gate declarations")
struct RouteGatePolicyTests {

  /// Every group that can mount a FaceTime, Send Later or FindMy sharing route.
  private var groups: [RouteGroup] {
    RouteTable.groups + [
      AdditiveRoutes.faceTime, AdditiveRoutes.faceTimeIncoming, AdditiveRoutes.sendLater,
      AdditiveRoutes.findMySharing,
    ]
  }

  private func gates(of id: HandlerID) -> [[RouteGate]] {
    groups.flatMap { group in
      group.routes.filter { $0.handlerID == id }.map { group.gates(for: $0) }
    }
  }

  /// `restart` relaunches FaceTime.app, which is maintenance rather than the capability the
  /// switch turns on, and it was never gated.
  private let ungatedFaceTime: Set<HandlerID> = [.facetimeRestart]

  @Test("Every FaceTime route sits behind the FaceTime switch")
  func faceTimeRoutesAreGated() {
    let routes = groups.flatMap { group in
      group.routes
        .filter { $0.handlerID.rawValue.hasPrefix("facetime.") }
        .filter { !ungatedFaceTime.contains($0.handlerID) }
        .map { (route: $0, gates: group.gates(for: $0)) }
    }
    #expect(routes.count >= 12, "the FaceTime routes were not found")
    for (route, gates) in routes {
      #expect(gates.first == .faceTime, "\(route.handlerID.rawValue) is not behind .faceTime")
    }
  }

  @Test("Dialling and hand-off add their own switch after FaceTime's")
  func narrowerSwitches() {
    #expect(gates(of: .facetimeCall) == [[.faceTime, .faceTimeOutgoingCalls]])
    #expect(gates(of: .facetimeHandoff) == [[.faceTime, .faceTimeIncomingHandoff]])
  }

  @Test("Every Send Later route sits behind the Send Later gate, the read included")
  func sendLaterRoutesAreGated() {
    let ids: [HandlerID] = [
      .messageSendLater, .messagePendingScheduled, .messageSendScheduledNow,
      .messageReschedule, .messageCancelScheduled,
    ]
    for id in ids {
      #expect(gates(of: id) == [[.sendLater]], "\(id.rawValue)")
    }
    #expect(
      AdditiveRoutes.sendLater.routes.map(\.handlerID).sorted { $0.rawValue < $1.rawValue }
        == ids.sorted { $0.rawValue < $1.rawValue })
  }

  /// Development builds only: a release build mounts no sharing routes at all.
  @Test("Sharing this Mac's location sits behind its flag")
  func findMySharingIsGated() {
    #if DEBUG
      for route in AdditiveRoutes.findMySharing.routes {
        #expect(
          AdditiveRoutes.findMySharing.gates(for: route) == [.findMyLocationSharing],
          "\(route.handlerID.rawValue)")
      }
    #endif
  }

  @Test("A group's gates come first, and a gate named twice is checked once")
  func gateOrder() throws {
    let group = RouteGroup(
      "Gated", requiring: [.faceTime],
      routes: [.init(.get, "x", .facetimeRecents, requiring: [.sendLater, .faceTime])])
    let route = try #require(group.routes.first)
    #expect(group.gates(for: route) == [.faceTime, .sendLater])
  }

  @Test("No handler checks a switch itself")
  func noHandlerChecksASwitch() throws {
    // The one file that evaluates the gates the table declares.
    let allowed: Set<String> = ["Sources/BBHandlers/RouteGates.swift"]
    let files = try SourceScanner.swiftFiles(under: "Sources/BBHandlers", minimum: 20)
      .filter { !allowed.contains($0.path) }
    let offences = SourceScanner.offences(in: files) { _, line in
      line.code.contains("requireOn(")
    }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue:
          "a handler checks a switch; declare `requiring:` on its route in RouteTable.swift:\n"
          + offences.report)
    )
  }
}
