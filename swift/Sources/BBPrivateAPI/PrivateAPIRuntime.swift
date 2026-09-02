//  PrivateAPIRuntime
//  The Private API as a registry service.
//
//  Gated rather than conditional: when the Private API is off, this service simply declines
//  to run and reports `.inactive`. That replaces the current `if privateApiEnabled` scattered
//  through startup, and it means "off" is a state the UI can show rather than an absence.
//
//  See `.claude/docs/private-api.md`.

import BBCore
import BBDiagnostics
import BBPrivateAPIContract
import BBServiceKit
import Foundation
import Logging

/// Everything the service needs that it should not decide for itself.
public struct PrivateAPIConfiguration: Sendable {
  public var isEnabled: Bool
  /// Path to the helper dylib to inject. Nil means the server does not manage injection —
  /// the user installed the helper some other way, and we only listen.
  public var dylibPath: String?
  /// Path to the FaceTime helper dylib. Nil means FaceTime is not injected — the common
  /// case, since the FaceTime flows are behind a feature flag.
  public var faceTimeDylibPath: String?
  public var injectionPolicy: InjectionPolicy
  /// Designated requirement a Swift-helper peer must satisfy on the socket transport.
  public var peerRequirement: String?
  public var socketPath: String?

  public init(
    isEnabled: Bool,
    dylibPath: String? = nil,
    faceTimeDylibPath: String? = nil,
    injectionPolicy: InjectionPolicy = .legacy,
    peerRequirement: String? = nil,
    socketPath: String? = nil
  ) {
    self.isEnabled = isEnabled
    self.dylibPath = dylibPath
    self.faceTimeDylibPath = faceTimeDylibPath
    self.injectionPolicy = injectionPolicy
    self.peerRequirement = peerRequirement
    self.socketPath = socketPath
  }
}

public actor PrivateAPIRuntime {

  private let configuration: PrivateAPIConfiguration
  private let logger: Logger
  private let alerts: (any AlertReporting)?

  private let transport: SocketTransport
  public let client: PrivateAPIClient
  /// One injector per app. Messages and FaceTime are separate processes with separate
  /// dylibs and separate sockets, so they inject, fail and retry independently.
  private var injectors: [String: DylibInjector] = [:]
  private var registrationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  /// How many times each helper has registered.
  ///
  /// A COUNT, not a flag, because "is it connected?" cannot answer "did the injection I just
  /// performed work?". Re-injecting an app that is already connected short-circuited on the
  /// EXISTING registration and reported success — measured: `mac/imessage/restart` returned
  /// 200 with Messages' pid unchanged, having done nothing at all. An injection now waits
  /// for a registration NEWER than the one it started with.
  private var registrationCounts: [String: Int] = [:]
  private var eventPump: Task<Void, Never>?

  public init(
    configuration: PrivateAPIConfiguration,
    alerts: (any AlertReporting)? = nil,
    logger: Logger = Logger(label: "bluebubbles.privateapi.service")
  ) {
    self.configuration = configuration
    self.alerts = alerts
    self.logger = logger

    // ONE transport, and it is the verifiable one. There is deliberately no loopback TCP
    // alternative: it cannot identify its peer, so any local process could connect and drive
    // the Private API. The socket lives inside Messages' container, where a sandboxed helper
    // can reach it — see `SocketLocation`.
    self.transport = SocketTransport(
      socketPath: configuration.socketPath,
      validator: configuration.peerRequirement.map {
        CodeSignaturePeerValidator(requirement: $0, logger: logger)
      } ?? CodeSignaturePeerValidator.messagesApp(logger: logger),
      logger: logger
    )
    self.client = PrivateAPIClient(transport: transport, logger: logger)
  }

  public var isConnected: Bool {
    get async { await transport.isConnected }
  }

  /// How long the whole start may take before the server gives up on it.
  ///
  /// Generous: injection quits and relaunches Messages, which is seconds on a busy Mac, and
  /// a deadline that fires on a slow machine would disable a working Private API.
  public static let startDeadline = Duration.seconds(90)

  /// Whether the last start completed, timed out, or was never attempted.
  ///
  /// Read by the UI so "the Private API is on" and "the Private API is working" stop being
  /// the same claim on screen.
  public private(set) var startOutcome: StartOutcome = .notStarted

  public enum StartOutcome: Sendable, Equatable {
    case notStarted
    case disabled
    case running
    /// The start did not finish inside `startDeadline`. The server continues without it.
    case timedOut
    case failed(String)
  }

  /// Bounded, so a Private API that cannot come up does not take the server with it.
  ///
  /// Everything inside is best-effort by design; what this adds is a ceiling. Injection
  /// quits and relaunches somebody else's app and then waits for a helper inside it to call
  /// back, and every step of that is at the mercy of processes this one does not control.
  /// Without a deadline the whole server start waits on the slowest of them — observed as a
  /// server whose port was open and which answered nothing, because startup never finished.
  ///
  /// A timeout is NOT a failure of the server. The Private API is optional; the documented
  /// position is that running without it is a supported configuration, not a degraded one.
  /// So the deadline logs, alerts, records the outcome, and returns — it does not throw.
  public func start() async throws {
    guard configuration.isEnabled else {
      logger.info("Private API is disabled; not starting")
      startOutcome = .disabled
      return
    }

    // A THROWN error still propagates. Injecting Messages is fatal when the Messages
    // Private API is switched on and cannot be injected — the server says so rather than
    // running half-configured — and the deadline must not quietly downgrade that to a
    // warning. Only OVERRUNNING is handled here; failing is still failing.
    enum Outcome {
      case finished
      case threw(any Error)
      case overran
    }

    let outcome = await withTaskGroup(of: Outcome.self) { group in
      group.addTask { [weak self] in
        do {
          try await self?.startUnbounded()
          return .finished
        } catch {
          return .threw(error)
        }
      }
      group.addTask {
        try? await Task.sleep(for: Self.startDeadline)
        return .overran
      }
      let first = await group.next() ?? .overran
      group.cancelAll()
      return first
    }

    if case .threw(let error) = outcome {
      startOutcome = .failed(describe(error))
      throw error
    }
    let completed = { if case .finished = outcome { return true } else { return false } }()

    guard completed else {
      startOutcome = .timedOut
      await raise(
        "The Private API did not finish starting",
        detail: "It took longer than \(Int(Self.startDeadline.components.seconds)) seconds "
          + "to inject and connect, so the server carried on without it. Reactions, "
          + "editing, unsending and typing indicators are unavailable until it connects. "
          + "Quitting and reopening Messages usually clears this."
      )
      return
    }
    if case .notStarted = startOutcome { startOutcome = .running }
  }

  private func startUnbounded() async throws {
    try await transport.start()
    startEventPump()

    guard configuration.dylibPath != nil || configuration.faceTimeDylibPath != nil else {
      // Listening only. A helper installed by other means still connects, which is how
      // a MacForge-style installation would work.
      logger.info("Private API listening; injection is not managed by the server")
      return
    }

    // Each app is injected only if ITS OWN switch is on. They are independent — different
    // dylibs, different processes, different sockets — so FaceTime can be injected on a
    // server that does not use the Messages Private API at all, and vice versa.
    if let dylibPath = configuration.dylibPath {
      // Messages' failure IS fatal: if the Messages Private API is switched on and
      // cannot be injected, the server should say so rather than run half-configured.
      try await injectManagedApp(
        applicationName: "Messages",
        bundleIdentifier: HelperHost.messages,
        dylibPath: dylibPath,
        required: true
      )
    }

    // FaceTime, when its own switch is on. Best effort rather than fatal: a Mac that
    // cannot inject FaceTime must still get a working Messages helper rather than a
    // server that refuses to start. The failure is raised as an alert either way, so it
    // is reported rather than swallowed.
    if let faceTimeDylib = configuration.faceTimeDylibPath {
      _ = try? await injectManagedApp(
        applicationName: "FaceTime",
        bundleIdentifier: HelperHost.faceTime,
        dylibPath: faceTimeDylib,
        required: false
      )
    }
  }

  /// Quits an app and relaunches it with its helper inserted.
  ///
  /// - Parameter required: whether a failure should propagate. A failure is always
  ///   reported; this only decides whether the caller treats it as fatal.
  @discardableResult
  private func injectManagedApp(
    applicationName: String,
    bundleIdentifier: String,
    dylibPath: String,
    required: Bool
  ) async throws -> Bool {
    let injector = DylibInjector(
      target: DylibInjector.Target(
        applicationName: applicationName,
        bundleIdentifier: bundleIdentifier,
        dylibPath: dylibPath
      ),
      policy: configuration.injectionPolicy,
      logger: logger
    )
    injectors[bundleIdentifier] = injector
    // Snapshotted BEFORE the app is touched, so a registration that lands while we are
    // still setting up still counts, and the one already in place does not.
    let baseline = registrationCounts[bundleIdentifier] ?? 0

    // Verified before anything is quit. Discovering an architecture mismatch AFTER
    // killing the user's Messages is a bad trade, and this is the failure dyld reports
    // only on stderr.
    do {
      try await injector.verify()
    } catch {
      await raise(
        "The \(applicationName) Private API helper cannot be injected",
        detail: describe(error)
      )
      if required { throw error }
      return false
    }

    do {
      try await injector.inject { [weak self] timeout in
        await self?.awaitRegistration(
          process: bundleIdentifier, after: baseline, timeout: timeout
        ) ?? false
      }
      return true
    } catch {
      await raise(
        "The \(applicationName) Private API helper did not start",
        detail: describe(error)
      )
      if required { throw error }
      return false
    }
  }

  /// Restarts one managed app with its helper injected.
  ///
  /// This is what the restart endpoints call. Restarting an app WITHOUT injection silently
  /// drops the Private API — the app comes back looking healthy and every Private API route
  /// starts reporting the helper as unavailable — so a plain relaunch is never the right
  /// thing to do when the server manages injection.
  ///
  /// Returns false when this app is not managed here, so a caller can fall back to a plain
  /// restart rather than reporting a failure.
  public func reinject(bundleIdentifier: String) async throws -> Bool {
    let paths: [String: String?] = [
      HelperHost.messages: configuration.dylibPath,
      HelperHost.faceTime: configuration.faceTimeDylibPath,
    ]
    let names = [
      HelperHost.messages: "Messages",
      HelperHost.faceTime: "FaceTime",
    ]
    guard let dylibPath = paths[bundleIdentifier] ?? nil,
      let applicationName = names[bundleIdentifier]
    else { return false }

    await injectors[bundleIdentifier]?.stop()
    return try await injectManagedApp(
      applicationName: applicationName,
      bundleIdentifier: bundleIdentifier,
      dylibPath: dylibPath,
      required: true
    )
  }

  public func stop() async {
    eventPump?.cancel()
    eventPump = nil
    for injector in injectors.values { await injector.stop() }
    injectors.removeAll()
    await transport.stop()
    for waiters in registrationWaiters.values {
      for waiter in waiters { waiter.resume() }
    }
    registrationWaiters.removeAll()
  }

  // MARK: - Registration

  /// Watches for the helper's `ping`, which is the only positive proof injection worked.
  ///
  /// Messages launching proves nothing: when dyld declines an inserted library it carries
  /// on without it, so the app comes up looking perfectly healthy.
  private func startEventPump() {
    eventPump = Task { [weak self] in
      guard let self else { return }
      for await event in await transport.events {
        if case .helperRegistered(let process, _, let rung) = event {
          // Logged where an operator will see it. The helper cannot report this
          // itself: os_log from an injected dylib inside a sandboxed host does not
          // reliably reach `log show`, measured on macOS 26.5.2 — so the capability
          // travels in the registration handshake and is surfaced here.
          self.logger.info(
            "Helper registered",
            metadata: [
              "process": .string(process),
              "inboundEvents": .string(rung ?? "unreported"),
            ])
          if rung == "none" {
            self.logger.warning(
              "The helper attached to no inbound-event source on this macOS; typing indicators will not be delivered"
            )
          }
          await self.registrationObserved(process: process)
        }
      }
    }
  }

  private func registrationObserved(process: String) {
    registrationCounts[process, default: 0] += 1
    for waiter in registrationWaiters.removeValue(forKey: process) ?? [] {
      waiter.resume()
    }
  }

  /// Waits for a registration of `process` newer than `after`.
  ///
  /// ONE named helper, never "any registration at all". Short-circuiting on whatever happens
  /// to be connected is wrong in both directions once there are two helpers: injecting
  /// FaceTime would report instant success because Messages was already registered, and a
  /// genuine FaceTime failure would look like a success.
  private func awaitRegistration(
    process: String, after baseline: Int, timeout: Duration
  ) async -> Bool {
    if (registrationCounts[process] ?? 0) > baseline { return true }
    return await withTaskGroup(of: Bool.self) { group in
      group.addTask { [weak self] in
        // Loops rather than returning on the first wake: a wake proves SOME
        // registration happened, not that it is newer than the baseline.
        while true {
          await withCheckedContinuation { continuation in
            Task { await self?.enqueue(waiter: continuation, for: process) }
          }
          if await self?.hasRegistered(process: process, after: baseline) == true {
            return true
          }
        }
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
  }

  func hasRegistered(process: String, after baseline: Int) -> Bool {
    (registrationCounts[process] ?? 0) > baseline
  }

  private func enqueue(waiter: CheckedContinuation<Void, Never>, for process: String) {
    registrationWaiters[process, default: []].append(waiter)
  }

  // MARK: - Reporting

  /// A failure here is a normal, reportable state — the Private API is an enhancement, and
  /// the server keeps running without it.
  private func raise(_ title: String, detail: String) async {
    logger.error("\(title)", metadata: ["detail": .string(detail)])
    await alerts?.raise(title: title, detail: detail)
  }

  private func describe(_ error: any Error) -> String {
    switch error {
    case DylibInjectionError.architectureMismatch(let dylib, let parent):
      // Named explicitly because it is invisible otherwise: dyld skips the library and
      // Messages starts normally, so the only symptom is a helper that never connects.
      return """
        The helper dylib is built for \(dylib.joined(separator: ", ")) but Messages \
        runs \(parent.joined(separator: ", ")). dyld will not load it, and it does \
        not report an error — Messages simply starts without it.
        """
    case DylibInjectionError.dylibMissing(let path):
      return "No helper dylib at \(path)."
    case DylibInjectionError.parentApplicationMissing(let name):
      return "\(name).app was not found. The server may lack Full Disk Access."
    case DylibInjectionError.helperNeverRegistered(let attempts):
      return """
        Messages restarted \(attempts) time(s) but the helper never connected. This \
        is usually System Integrity Protection still being enabled.
        """
    default:
      return String(describing: error)
    }
  }
}
