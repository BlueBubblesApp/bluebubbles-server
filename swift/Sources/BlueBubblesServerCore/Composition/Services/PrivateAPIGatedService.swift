//  PrivateAPIGatedService
//  The Private API as a registry service: inject, connect, forward helper events onto the bus.

import BBDiagnostics
import BBEvents
import BBPrivateAPI
import BBPrivateAPIContract
import BBSerialization
import BBServiceKit
import BBSettings
import Foundation

final class PrivateAPIGatedService: ContextualService, GatedService, ConfigurableService {
  static let manifest = BuiltInManifests.privateAPI
  static let watchedSettings: Set<String> = [
    Settings.enablePrivateAPI.key, Settings.privateAPIHelperPath.key,
    // Changing which FaceTime dylib is injected has to re-inject it, same as the
    // Messages one — and so does turning FaceTime injection on or off.
    Settings.privateAPIFaceTimeHelperPath.key, Settings.enableFaceTimePrivateAPI.key,
  ]
  static let restartPolicy = RestartPolicy.backoff(
    base: .seconds(5), max: .seconds(60), attempts: 5
  )

  let context: AppContext
  /// Built in `start()` rather than `init`, because its configuration comes from settings
  /// and the initializer is synchronous. A runtime constructed here with `isEnabled: false`
  /// never opens a socket and never injects, so the helper has nothing to connect to and
  /// every Private API endpoint reports the helper as unavailable on a machine where it
  /// would work.
  private let runtime = RuntimeBox()
  /// Forwards helper events onto the event bus. Held so it stops with the service.
  private let pump = TaskBox()

  init(host: AppContext) {
    self.context = host
  }

  /// Declining is a normal state, not a failure. This is what replaces the inline
  /// `if privateApiEnabled` in startServices().
  /// Runs when EITHER helper is wanted.
  ///
  /// The two are independent: different dylibs, injected into different apps, connecting to
  /// different sockets. They share only this transport, so FaceTime does not need the
  /// Messages Private API switched on. (One soft link remains: the FaceTime call pre-flight
  /// asks the MESSAGES helper whether an address is FaceTime-capable, and without it that
  /// check simply cannot answer — an unverifiable address is allowed through rather than
  /// refused. See `requireFaceTimeCapable`.)
  func canRun() async -> Bool {
    let messages = await context.settings.get(Settings.enablePrivateAPI)
    let faceTime = await context.settings.get(Settings.enableFaceTimePrivateAPI)
    return messages || faceTime
  }

  func start() async throws {
    let settings = context.settings
    let configuration = PrivateAPIConfiguration(
      isEnabled: true,
      dylibPath: await settings.get(Settings.enablePrivateAPI)
        ? await Self.resolveHelperPath(settings: settings)
        : nil,
      // Injected AT STARTUP when the FaceTime toggle is on, alongside Messages.
      // Injection quits and relaunches the app, so doing it lazily — on the first
      // client call to a FaceTime route — would restart FaceTime.app underneath
      // someone mid-request and fail that call. Both helpers come up with the server,
      // so every Private API route works from the first request.
      faceTimeDylibPath: await settings.get(Settings.enableFaceTimePrivateAPI)
        ? await Self.resolveFaceTimeHelperPath(settings: settings)
        : nil,
      injectionPolicy: .legacy,
      // Validated against Messages.app's own signature. The peer on this socket IS
      // Messages — the helper runs inside it — so this is what stops any other local
      // process from driving the Private API.
      peerRequirement: nil
    )

    let runtime = PrivateAPIRuntime(
      configuration: configuration,
      // Coalesced: injection retries, and a failing retry loop would otherwise produce one
      // alert per attempt.
      alerts: AlertCenterReporter(
        center: context.alerts, source: "PrivateAPI", dedupeKey: "private-api.injection"
      ),
      logger: context.logger
    )
    await self.runtime.set(runtime)

    // Attached BEFORE start: injection quits and relaunches Messages and can take tens
    // of seconds, and the interfaces should hold the client for that whole time rather
    // than reporting "no Private API" until it finishes.
    await context.publishPrivateAPI(client: runtime.client, runtime: runtime)

    try await runtime.start()

    // Helper events onto the bus.
    //
    // The decoder turns typing, FindMy, alias-removal and FaceTime notifications into
    // `PrivateAPIEvent`s, and nothing forwarded them: the only consumer of the stream
    // matched `helperRegistered` and discarded the rest. So a whole family of
    // client-visible events was decoded correctly and thrown away — typing indicators in
    // particular are the most visible thing the Private API provides.
    let client = await runtime.client
    let events = context.events
    let logger = context.logger
    let cleanupContext = context
    await pump.set(
      Task {
        for await event in client.events {
          // The FaceTime helper registering is the ONLY moment stray links can be
          // cleared: invalidation needs link objects, and the list that holds them is
          // populated at FaceTime's process start and never refreshed (the delegate that
          // would refresh it crashes FaceTime.app). So the sweep rides on registration
          // rather than a timer — a timer would find nothing, every time.
          if case .helperRegistered(let process, _, _) = event,
            process == HelperHost.faceTime
          {
            await Self.sweepFaceTime(context: cleanupContext)
          }
          guard let (server, key) = Self.serverEvent(for: event) else { continue }
          await events.emit(server, rateLimitKey: key)
        }
        logger.debug("Private API event pump stopped")
      })
  }

  func stop() async {
    await pump.cancel()
    // The hand-off watchers and any pending app restart poll the helper that is about to go
    // away. Cancelled here because this service is the helper's lifecycle.
    await context.faceTime().stop()
    await context.applicationRestart().stop()
    // Withdrawn BEFORE the runtime is torn down, and both halves together. Clearing them
    // separately either side of `stop()` left the client published against a runtime that
    // was already gone.
    await context.withdrawPrivateAPI()
    await self.runtime.current?.stop()
    await self.runtime.set(nil)
  }

  /// Maps a helper event onto the client-facing vocabulary.
  ///
  /// The second element is the rate-limit key. It matters for FindMy: locations arrive as
  /// a batch covering every device, and keying on the DEVICE is what makes the limiter
  /// deliver each device's newest position rather than one device's and nobody else's.
  /// The automatic sweep: expired server-created links, plus any call the Mac is stuck in.
  ///
  /// Deliberately quiet. This runs on every registration, and the common case is that there
  /// is nothing to do; only actual work is logged.
  /// The automatic sweep: expired server-created links, plus any call the Mac is stuck in.
  ///
  /// Deliberately quiet. This runs on every registration and the common case is that there
  /// is nothing to do, so only actual work is worth a line.
  private static func sweepFaceTime(context: AppContext) async {
    let result = await context.faceTime().cleanUp(clearAll: false)
    guard !result.links.isEmpty || !result.calls.isEmpty else { return }
    context.logger.info(
      "FaceTime cleanup on helper registration",
      metadata: [
        "links": .stringConvertible(result.links.count),
        "calls": .stringConvertible(result.calls.count),
      ])
  }

  static func serverEvent(
    for event: PrivateAPIEvent
  ) -> (event: ServerEvent, rateLimitKey: String?)? {
    switch event {
    case .helperRegistered:
      // Connection bookkeeping, not something a client is told about.
      return nil

    case .typingChanged(let chat, let isTyping):
      let payload = JSONValue.object([
        "guid": .string(chat.rawValue),
        "display": .bool(isTyping),
      ])
      return (
        ServerEvent(
          name: .typingIndicator, fullPayload: payload, notificationPayload: payload
        ),
        chat.rawValue
      )

    case .iMessageAliasesRemoved(let aliases):
      let payload = JSONValue.object([
        "aliases": .array(aliases.map(JSONValue.string))
      ])
      return (
        ServerEvent(
          name: .iMessageAliasesRemoved,
          fullPayload: payload,
          notificationPayload: payload
        ),
        nil
      )

    case .findMyLocationUpdated(let payload):
      let body = JSONValue.object(payload.mapValues(JSONValue.string))
      // No key, deliberately. FindMy's limit is global — see `EventRouting.policy` —
      // because it protects Apple's service from this server rather than protecting
      // this server's own delivery from a busy chat. Keying it per device would
      // multiply the permitted request rate by the number of devices.
      return (
        ServerEvent(
          name: .newFindMyLocation, fullPayload: body, notificationPayload: body
        ),
        nil
      )

    case .faceTimeCallChanged(let call, let payload):
      // The typed call plus the raw fields the contract does not model. An incoming
      // call is delivered under the same event with `status = incoming`, which is the
      // signal a client turns into "answer via the API."
      var fields = payload.mapValues(JSONValue.string)
      fields["callUuid"] = .string(call.callUUID)
      fields["status"] = .string(call.status.name)
      fields["callStatus"] = .int(call.status.rawValue)
      if let handle = call.handle { fields["address"] = .string(handle.value) }
      let body = JSONValue.object(fields)
      return (
        ServerEvent(
          name: call.status == .incoming ? .incomingFaceTime : .faceTimeCallStatusChanged,
          fullPayload: body,
          notificationPayload: body
        ),
        call.callUUID
      )

    case .faceTimeMembershipChanged(let conversationUUID, let members):
      // Consumed by the server's FaceTime session state machine to decide when the Mac
      // may drop. Not forwarded to clients as its own event yet — the client cares about
      // the link and the call status, not raw membership churn.
      let body = JSONValue.object([
        "conversationUuid": .string(conversationUUID),
        "members": .array(
          members.map { member in
            JSONValue.object([
              "address": .string(member.handle.value),
              "isPending": .bool(member.isPending),
            ])
          }),
      ])
      return (
        ServerEvent(
          name: .faceTimeCallStatusChanged,
          fullPayload: body,
          notificationPayload: body
        ),
        conversationUUID
      )
    }
  }

  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  var health: ServiceHealth {
    get async {
      guard let runtime = await runtime.current else {
        return .degraded(reason: "not started")
      }
      guard await runtime.isConnected else {
        return .degraded(reason: "no helper connected")
      }
      return .running
    }
  }

  /// Where the dylib is, in order of preference.
  ///
  /// The bundled copy first, because that is what a released install uses and it is inside
  /// the signed, notarized container. The setting is the development escape hatch.
  /// Same resolution order as the Messages helper, against the FaceTime dylib.
  static func resolveFaceTimeHelperPath(settings: SettingsStore) async -> String? {
    let configured = await settings.get(Settings.privateAPIFaceTimeHelperPath)
    if !configured.isEmpty { return configured }

    if let bundled = Bundle.main.url(
      forResource: "libBlueBubblesFaceTimeHelper", withExtension: "dylib"
    ) {
      return bundled.path
    }
    let frameworks = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Frameworks/libBlueBubblesFaceTimeHelper.dylib")
    if FileManager.default.fileExists(atPath: frameworks.path) { return frameworks.path }
    return nil
  }

  static func resolveHelperPath(settings: SettingsStore) async -> String? {
    let configured = await settings.get(Settings.privateAPIHelperPath)
    if !configured.isEmpty { return configured }

    if let bundled = Bundle.main.url(forResource: "libBlueBubblesHelper", withExtension: "dylib") {
      return bundled.path
    }
    let frameworks = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Frameworks/libBlueBubblesHelper.dylib")
    if FileManager.default.fileExists(atPath: frameworks.path) { return frameworks.path }

    // Nil means "listen, but do not manage injection" — a helper installed some other
    // way still connects. That is a supported configuration, not a failure.
    return nil
  }
}
