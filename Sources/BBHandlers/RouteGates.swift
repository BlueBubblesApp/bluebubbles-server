//  RouteGates
//  What each `RouteGate` the route table declares means, and the refusal when it is closed.
//
//  The table names a gate (`requiring: [.faceTime]`) and `HTTPAPIBuilder` checks it before
//  the body is read; this is the one place that says which setting, flag or capability stands
//  behind each name. The switch is exhaustive, so a gate added to the table does not compile
//  until it means something here.
//
//  A handler never checks a switch itself: `RouteGatePolicyTests` fails the build on a
//  `requireOn(` in this directory and holds each gated route to its declaration. A check
//  copied into every handler is how one route comes to be the one that forgot it.

import BBHTTPAPI
import BBInterfaces
import BBSettings

public enum RouteGates {

  /// The stage the router runs, evaluating against `context`.
  public static func stage(
    context: some SettingsProviding & InterfaceProviding
  ) -> RouteGateStage {
    RouteGateStage { gate in try await check(gate, context: context) }
  }

  /// Returns when `gate` is open, and throws its refusal when it is not.
  ///
  /// The switches throw `requireOn`'s `InterfaceError.serviceDisabled`, a 403 naming the
  /// setting or flag to turn on: the response these routes gave when their handlers checked.
  /// Send Later throws `MessageInterface.requireSendLaterSupported`'s 400, which is the
  /// interface's own refusal, so a caller that is not HTTP meets the same one.
  public static func check(
    _ gate: RouteGate, context: some SettingsProviding & InterfaceProviding
  ) async throws {
    switch gate {
    case .faceTime:
      try await context.requireOn(Settings.enableFaceTimePrivateAPI)
    case .faceTimeOutgoingCalls:
      try await context.requireOn(Settings.faceTimeOutgoingCalls)
    case .faceTimeIncomingHandoff:
      try await context.requireOn(Settings.faceTimeIncomingHandoff)
    case .findMyLocationSharing:
      try await context.requireOn(Features.findMyLocationSharing)
    case .sendLater:
      try await context.requireInterfaces().message.requireSendLaterSupported()
    }
  }
}
