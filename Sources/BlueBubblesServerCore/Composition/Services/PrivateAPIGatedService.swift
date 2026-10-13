//  PrivateAPIGatedService
//  The Private API as a registry service: inject, connect, forward helper events onto the bus.

import BBBuiltIns
import BBCore
import BBDiagnostics
import BBEvents
import BBFaceTime
import BBInterfaces
import BBPrivateAPI
import BBPrivateAPIContract
import BBSerialization
import BBServiceKit
import BBSettings
import Foundation
import Logging

actor PrivateAPIGatedService: Service, GatedService, ConfigurableService {
  static let manifest = BuiltInManifests.privateAPI
  static let restartPolicy = RestartPolicy.backoff(
    base: .seconds(5), max: .seconds(60), attempts: 5
  )

  /// What this service touches, rather than the container that holds it.
  typealias Host = any ScopedSettingsProviding & AlertProviding & LoggerProviding & EventPublishing
    & FaceTimeProviding & ApplicationRestarting & PrivateAPIPublishing & HealthChangeReporting
    & InterfaceProviding
  /// What the FaceTime sweep needs: it cleans up and says what it did.
  typealias Sweeping = any FaceTimeProviding & LoggerProviding

  private let host: Host
  private let scoped: ScopedSettings
  private let events: EventBus
  private let logger: Logger
  /// Built in `start()` rather than `init`, because its configuration comes from settings
  /// and the initializer is synchronous. A runtime constructed here with `isEnabled: false`
  /// never opens a socket and never injects, so the helper has nothing to connect to and
  /// every Private API endpoint reports the helper as unavailable on a machine where it
  /// would work.
  private var runtime: PrivateAPIRuntime?
  /// Forwards helper events onto the event bus. Held so it stops with the service.
  private let pump = OwnedTask()

  init(host: Host) {
    self.host = host
    self.scoped = host.scopedSettings(for: Self.manifest)
    self.events = host.events
    self.logger = host.logger
  }

  /// Declining is a normal state, not a failure.
  /// Runs when EITHER helper is wanted.
  ///
  /// The two are independent: different dylibs, injected into different apps, connecting to
  /// different sockets. They share only this transport, so FaceTime does not need the
  /// Messages Private API switched on. (One soft link remains: the FaceTime call pre-flight
  /// asks the MESSAGES helper whether an address is FaceTime-capable, and without it that
  /// check simply cannot answer: an unverifiable address is allowed through rather than
  /// refused. See `requireFaceTimeCapable`.)
  func canRun() async -> Bool {
    let messages = await scoped.valueOrDefault(Settings.enablePrivateAPI)
    let faceTime = await scoped.valueOrDefault(Settings.enableFaceTimePrivateAPI)
    return messages || faceTime
  }

  /// The injection configuration, read fresh from the settings store.
  ///
  /// Factored out of `start()` so `apply(_:)` can rebuild it without restarting the service:
  /// see the note there on why a FaceTime setting must not relaunch Messages.
  private func makeConfiguration() async throws -> PrivateAPIConfiguration {
    let scoped = self.scoped
    return PrivateAPIConfiguration(
      isEnabled: true,
      dylibPath: try await scoped.get(Settings.enablePrivateAPI)
        ? await Self.resolveHelperPath(settings: scoped)
        : nil,
      // Injected AT STARTUP when the FaceTime toggle is on, alongside Messages.
      // Injection quits and relaunches the app, so doing it lazily (on the first
      // client call to a FaceTime route) would restart FaceTime.app underneath
      // someone mid-request and fail that call. Both helpers come up with the server,
      // so every Private API route works from the first request.
      faceTimeDylibPath: try await scoped.get(Settings.enableFaceTimePrivateAPI)
        ? await Self.resolveFaceTimeHelperPath(settings: scoped)
        : nil,
      injectionPolicy: .legacy,
      // Validated against Messages.app's own signature. The peer on this socket IS
      // Messages (the helper runs inside it) so this is what stops any other local
      // process from driving the Private API.
      peerRequirement: nil,
      // Read here rather than in the helper: the helper is inside FaceTime's sandbox and
      // cannot reach the settings store. It arrives through the injection environment.
      faceTimeIdleCameraOff: try await scoped.get(Settings.faceTimeIdleCameraOff)
    )
  }

  func start() async throws {
    let configuration = try await makeConfiguration()

    let runtime = PrivateAPIRuntime(
      configuration: configuration,
      // Coalesced: injection retries, and a failing retry loop would otherwise produce one
      // alert per attempt.
      alerts: AlertCenterReporter(
        center: host.alerts, source: "PrivateAPI", dedupeKey: "private-api.injection"
      ),
      // Its own label, not the host's root logger: the runtime hands this to the socket
      // transport and the client too, and a request/reply line is filtered by subsystem.
      logger: Logger(label: "bluebubbles.privateapi")
    )
    self.runtime = runtime

    // Attached BEFORE start: injection quits and relaunches Messages and can take tens
    // of seconds, and the interfaces should hold the client for that whole time rather
    // than reporting "no Private API" until it finishes.
    await host.publishPrivateAPI(client: runtime.client, runtime: runtime)
    // Published, so anyone following the runtime's state can start now: during
    // injection, which is when the state is worth watching.
    await host.serviceHealthDidChange(Self.id)

    // Helper events onto the bus.
    //
    // The decoder turns typing, FindMy, alias-removal and FaceTime notifications into
    // `PrivateAPIEvent`s, and nothing forwarded them: the only consumer of the stream
    // matched `helperRegistered` and discarded the rest. So a whole family of
    // client-visible events was decoded correctly and thrown away: typing indicators in
    // particular are the most visible thing the Private API provides.
    //
    // SUBSCRIBED BEFORE `runtime.start()`, and the order is load-bearing. Injection happens
    // inside that call, and both helpers register while it runs. A subscription taken after
    // it returns misses those registrations on every cold start, which silently disabled
    // the FaceTime link sweep below, and with it the `facetime_link_ttl_hours` setting,
    // because registration is the only trigger that sweep has. It survived review because
    // it is invisible after startup: a FaceTime restart later re-registers and does sweep.
    let client = await runtime.client
    let events = self.events
    let logger = self.logger
    let cleanupContext: Sweeping = host
    let scoped = self.scoped
    let healthHost: any HealthChangeReporting = host
    let handles: any InterfaceProviding = host
    // The calls already announced as incoming, so a ringing call is announced once however
    // many status changes it goes through: the reference's `FaceTimeSessionManager.addSession`.
    let announced = Locked(Set<String>())
    pump.run {
      for await event in client.events {
        // `health` reads whether a helper is connected, so the registry's stream is told
        // at both edges.
        switch event {
        case .helperRegistered, .helperDisconnected:
          await healthHost.serviceHealthDidChange(Self.id)
        default: break
        }
        // The FaceTime helper registering is the ONLY moment stray links can be
        // cleared: invalidation needs link objects, and the list that holds them is
        // populated at FaceTime's process start and never refreshed (the delegate that
        // would refresh it crashes FaceTime.app). So the sweep rides on registration
        // rather than a timer: a timer would find nothing, every time.
        if case .helperRegistered(let process, _, _) = event,
          process == HelperHost.faceTime
        {
          await Self.sweepFaceTime(
            context: cleanupContext,
            linkTTLHours: await scoped.valueOrDefault(Settings.faceTimeLinkTTLHours))
        }
        let mapped: (event: ServerEvent, rateLimitKey: String?)?
        if case .faceTimeCallChanged(let call, let payload) = event {
          let calling = await scoped.valueOrDefault(Settings.faceTimeIncomingHandoff)
          let isNew = announced.withLock { $0.insert(call.callUUID).inserted }
          let handle: JSONValue? =
            if let address = call.handle?.value, calling,
              let interfaces = await handles.interfaces(),
              let found = try? await interfaces.handle.find(address: address)
            {
              // `try?`: a handle that cannot be read is the reference's `null`, which is
              // what this field carries for an address chat.db has never seen.
              interfaces.handle.serialize(found)
            } else { nil }
          mapped = Self.faceTimeEvent(
            call, payload: payload, calling: calling, isNewSession: isNew, handle: handle,
            now: Date())
        } else {
          mapped = Self.serverEvent(for: event)
        }
        guard let (server, key) = mapped else { continue }
        // Typing is per keystroke burst and would drown the rest at debug. The key is
        // a chat GUID for chat-scoped events, so it is redacted.
        logger.log(
          level: server.name == .typingIndicator ? .trace : .debug,
          "Announcing helper event",
          metadata: [
            "event": .string(server.name.rawValue),
            "chat": .string(key.map(Redaction.chatGUID) ?? "-"),
          ])
        await events.emit(server, rateLimitKey: key)
      }
      logger.debug("Private API event pump stopped")
    }

    // `PrivateAPIRuntime.start` BINDS THE TRANSPORT before it injects, and the pump and the
    // published client are attached above, so a throw here leaves all three behind. The
    // registry stops a service whose start threw before it retries or gives up
    // (`Service.start()`), and `stop()` takes down exactly these; a retry that ran on top of
    // them leaked a bound socket per attempt.
    try await runtime.start()
  }

  func stop() async {
    // The hand-off watchers and any pending app restart poll the helper that is about to go
    // away. Cancelled here because this service is the helper's lifecycle.
    await host.faceTime().stop()
    await host.applicationRestart().stop()
    // Withdrawn BEFORE the runtime is torn down, and both halves together. Clearing them
    // separately either side of `stop()` left the client published against a runtime that
    // was already gone.
    await host.withdrawPrivateAPI()
    await self.runtime?.stop()
    self.runtime = nil
    // LAST, and that is the only bound the wait has. The pump can be parked in the FaceTime
    // sweep on a helper request, which nothing but the runtime's stop fails: waited for any
    // earlier, a stop sat out the request's timeout. Stopping the runtime also finishes the
    // event stream, so by here the pump is returning on its own.
    await pump.stop()
  }

  /// The automatic sweep: expired server-created links, plus any call the Mac is stuck in.
  ///
  /// Deliberately quiet. This runs on every registration and the common case is that there
  /// is nothing to do, so only actual work is worth a line.
  private static func sweepFaceTime(context: Sweeping, linkTTLHours: Int) async {
    let result = await context.faceTime().cleanUp(.expired(linkTTLHours: linkTTLHours))
    guard !result.links.isEmpty || !result.calls.isEmpty else { return }
    context.logger.info(
      "FaceTime cleanup on helper registration",
      metadata: [
        "links": .stringConvertible(result.links.count),
        "calls": .stringConvertible(result.calls.count),
      ])
  }

  /// Maps a helper event onto the client-facing vocabulary.
  ///
  /// The second element is the rate-limit key. It matters for FindMy: locations arrive as
  /// a batch covering every device, and keying on the DEVICE is what makes the limiter
  /// deliver each device's newest position rather than one device's and nobody else's.
  static func serverEvent(
    for event: PrivateAPIEvent
  ) -> (event: ServerEvent, rateLimitKey: String?)? {
    switch event {
    case .helperRegistered, .helperDisconnected:
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
      // No key, deliberately. FindMy's limit is global (see `EventRouting.policy`)
      // because it protects Apple's service from this server rather than protecting
      // this server's own delivery from a busy chat. Keying it per device would
      // multiply the permitted request rate by the number of devices.
      return (
        ServerEvent(
          name: .newFindMyLocation, fullPayload: body, notificationPayload: body
        ),
        nil
      )

    case .faceTimeCallChanged:
      // Needs the settings, the session memory and chat.db, none of which a static has;
      // `faceTimeEvent` below, called by the pump.
      return nil

    case .faceTimeMembershipChanged:
      // Bookkeeping for the hand-off, which follows membership itself. The reference has
      // no event for it, and this used to go out as `ft-call-status-changed` with a shape
      // of its own, which a client reading that event for a call's status could not read.
      return nil
    }
  }

  /// A call's status change as the reference announces it, which depends on its
  /// `facetime_calling` (`PrivateApiFaceTimeStatusHandler.ts`), here
  /// `facetime_incoming_handoff`:
  ///
  /// - **Off**: only a call ringing here, as `incoming-facetime`, and the payload is a JSON
  ///   STRING, `{"caller": …, "timestamp": …}`, stringified "to maintain backwards compat".
  /// - **On**: `ft-call-status-changed` in a fixed snake_case shape. An outgoing call and an
  ///   answered one are not announced, and an incoming one only the first time.
  ///
  /// Nil when the reference would send nothing, including a status change with no address:
  /// the reference reads `handle.value` unguarded and throws before it emits.
  static func faceTimeEvent(
    _ call: FaceTimeCall, payload: [String: String], calling: Bool, isNewSession: Bool,
    handle: JSONValue?, now: Date
  ) -> (event: ServerEvent, rateLimitKey: String?)? {
    guard calling else {
      guard call.status == .incoming else { return nil }
      var object: [String: JSONValue] = ["timestamp": .int64(now.epochMilliseconds)]
      if let caller = call.handle?.value { object["caller"] = .string(caller) }
      guard let text = try? JSONValue.object(object).serialize() else { return nil }
      let body = JSONValue.string(String(decoding: text, as: UTF8.self))
      return (
        ServerEvent(name: .incomingFaceTime, fullPayload: body, notificationPayload: body),
        call.callUUID
      )
    }
    switch call.status {
    case .outgoing, .answered: return nil
    case .incoming where !isNewSession: return nil
    default: break
    }
    guard let address = call.handle?.value else { return nil }
    func flag(_ key: String) -> Bool? {
      payload[key].map { Bool(loose: $0) ?? false }
    }
    let body = JSONValue.object([
      "uuid": .string(call.callUUID),
      "status": .string(call.status.name),
      "status_id": .int(call.status.rawValue),
      "ended_error": payload["ended_error"].map(JSONValue.string) ?? .null,
      "ended_reason": payload["ended_reason"].map(JSONValue.string) ?? .null,
      "address": .string(address),
      "handle": handle ?? .null,
      "image_url": payload["image_url"].map(JSONValue.string) ?? .null,
      "is_outgoing": .bool(flag("is_outgoing") ?? false),
      "is_audio": .bool(flag("is_sending_audio") ?? false),
      "is_video": .bool(flag("is_sending_video") ?? call.isVideo),
    ])
    return (
      ServerEvent(name: .faceTimeCallStatusChanged, fullPayload: body, notificationPayload: body),
      call.callUUID
    )
  }

  /// Settings that belong to the MESSAGES helper. FindMy rides in that helper too: its
  /// bridge is `Helper/BlueBubblesHelper/FindMyBridge.swift`, not a third dylib, so a FindMy
  /// setting added here re-injects Messages and leaves FaceTime running.
  static let messagesKeys: Set<String> = [
    Settings.enablePrivateAPI.key, Settings.privateAPIHelperPath.key,
  ]

  /// Settings that belong to the FACETIME helper.
  static let faceTimeKeys: Set<String> = [
    Settings.enableFaceTimePrivateAPI.key, Settings.privateAPIFaceTimeHelperPath.key,
    Settings.faceTimeIdleCameraOff.key,
  ]

  /// Re-injects ONLY the helper whose settings changed.
  ///
  /// **The two helpers are independent and must be restarted independently.** They are
  /// separate dylibs in separate apps on separate sockets, and this service owns both only
  /// because they share a transport. Returning `.restart` for any change would make the
  /// registry stop and start the whole service, which re-injects BOTH, so toggling
  /// "Turn the camera off in the background" would quit and relaunch the user's
  /// Messages.app, for a setting that has nothing to do with Messages. Injection is not a
  /// cheap operation to inflict by accident: it terminates somebody's app.
  ///
  /// `.reconfigure` is the honest answer (the change IS absorbed here) and the registry
  /// then leaves the service alone.
  ///
  /// The one case that still restarts is both helpers going away, because that is not a
  /// reconfiguration: the service's own gate (`canRun`) no longer passes, and only a restart
  /// makes the registry re-evaluate it and record the service as inactive.
  func apply(_ change: SettingsChange) async throws -> ReloadAction {
    guard let runtime else { return .none }
    let messages = change.intersects(Self.messagesKeys)
    let faceTime = change.intersects(Self.faceTimeKeys)
    guard messages || faceTime else { return .none }

    let updated = try await makeConfiguration()
    guard updated.dylibPath != nil || updated.faceTimeDylibPath != nil else { return .restart }
    await runtime.reconfigure(updated)

    // Turning one OFF stops managing that app rather than re-injecting it. The app keeps
    // running with the helper it already loaded until something relaunches it, and the
    // OTHER app is not disturbed.
    if messages {
      if updated.dylibPath == nil {
        await runtime.stopInjecting(bundleIdentifier: HelperHost.messages)
      } else {
        _ = try? await runtime.reinject(bundleIdentifier: HelperHost.messages)
      }
    }
    if faceTime {
      if updated.faceTimeDylibPath == nil {
        await runtime.stopInjecting(bundleIdentifier: HelperHost.faceTime)
      } else {
        _ = try? await runtime.reinject(bundleIdentifier: HelperHost.faceTime)
      }
    }
    return .reconfigure
  }

  var health: ServiceHealth {
    get async {
      guard let runtime else {
        return .degraded(reason: ServiceHealth.RoutineReason.notStarted)
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
  static func resolveFaceTimeHelperPath(settings: ScopedSettings) async -> String? {
    let configured = await settings.valueOrDefault(Settings.privateAPIFaceTimeHelperPath)
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

  static func resolveHelperPath(settings: ScopedSettings) async -> String? {
    let configured = await settings.valueOrDefault(Settings.privateAPIHelperPath)
    if !configured.isEmpty { return configured }

    if let bundled = Bundle.main.url(forResource: "libBlueBubblesHelper", withExtension: "dylib") {
      return bundled.path
    }
    let frameworks = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Frameworks/libBlueBubblesHelper.dylib")
    if FileManager.default.fileExists(atPath: frameworks.path) { return frameworks.path }

    // Nil means "listen, but do not manage injection": a helper installed some other
    // way still connects. That is a supported configuration, not a failure.
    return nil
  }
}
