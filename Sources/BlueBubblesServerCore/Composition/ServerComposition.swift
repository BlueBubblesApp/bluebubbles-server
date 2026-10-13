//  ServerComposition
//  Building the server, once, in one place.
//
//  Everything above this type takes what it needs as a parameter. This is the only code that
//  knows the whole graph, and it is deliberately readable top to bottom: `assemble`, below,
//  calls every step in the order it happens, so what starts before what is answered by
//  reading one function, not by tracing.
//
//  Three properties this is responsible for:
//
//    1. **The server starts even when things are wrong.** No Full Disk Access, no Firebase,
//       no helper: it still comes up, so the user can reach the UI and fix it. A server that
//       refuses to boot cannot tell anyone why it refused.
//    2. **Optional subsystems stay absent when unconfigured.** Push with no credentials and
//       token auth under the default mode are not disabled features holding resources; they
//       are never constructed, and their routes are never registered.
//    3. **Start order is derived, stop order is its exact reverse.** Both come from the
//       declared dependency graph rather than from two hand-maintained lists.
//
//  Each step lives in a sibling file named for its concern: `+Configuration` (the options
//  and the config file), `+Storage`, `+ServiceSettings` (what runs before anything is
//  built), `+ReadPath`, `+SharedServices`, `+Transport`, `+Services` (the registry, the
//  service list and settings propagation), `+Routes`, and `+RunningServer` (start and stop).
//  Tests that pin a wiring line read the whole family through `SourceScanner.family`.
//
//  See `.claude/docs/architecture.md`.

import BBBuiltIns
import BBCore
import BBIMessage
import BBSettings
import BBTooling
import Logging

public struct ServerComposition {

  /// Builds every long-lived object and returns the assembled server.
  ///
  /// Opens its own storage. Callers that already have some (because they had to inspect it
  /// first) pass it to `build(storage:options:)` instead.
  public static func build(options: Options = Options()) async throws -> RunningServer {
    try await build(storage: try await prepareStorage(options: options), options: options)
  }

  /// Builds from storage somebody else opened.
  ///
  /// The steps, in the order they happen: refuse an install nobody has adopted, move each
  /// service's settings into the shape it expects, open the read path, build the services
  /// that everything else leans on, build the transport, assemble the context, register
  /// the services, and hand back the assembled server.
  ///
  /// Each step is a function in the `ServerComposition+*` file named for its concern, called
  /// here in order, so this reads top to bottom and each step is short enough to hold in
  /// one's head.
  public static func build(
    storage: Storage, options: Options = Options()
  ) async throws -> RunningServer {
    // Everything assembly writes (seeded defaults, adopted certificates, migrated service
    // settings) is the SERVER's doing, and the audit log attributes it so. See `AuditContext`.
    try await AuditContext.acting(as: .system(component: "startup")) {
      try await assemble(storage: storage, options: options)
    }
  }

  private static func assemble(
    storage: Storage, options: Options
  ) async throws -> RunningServer {
    let logger = storage.logger
    let settings = storage.settings

    try await refuseUnadoptedInstall(settings: settings)
    // The validator's verdict, carried to registration. A service the validator REFUSED is
    // not registered, so it cannot start, and a fatally invalid manifest never runs.
    let refusedServices = await prepareServiceSettings(settings: settings, logger: logger)

    // Built here rather than inside the read path or the service, because BOTH need it and
    // they need the same one.
    let searchIndex = SearchIndexStore(logger: logger)
    let readPath = await openReadPath(
      settings: settings, logger: logger, searchIndex: searchIndex)
    let shared = await makeSharedServices(storage: storage)
    let transport = await makeTransport(
      storage: storage, accessControl: shared.accessControl, auditLog: shared.auditLog)

    // Decided before the context is built, because the HTTP service mounts them and is
    // constructed by the registry with nothing but a context to read from.
    let additionalGroups = await routeGroups(
      authMode: transport.authMode,
      codecs: transport.codecs,
      features: Set(
        await settings.featureStates().filter(\.value).keys.map(\.id)
      ),
      faceTime: await settings.get(Settings.enableFaceTimePrivateAPI),
      faceTimeIncoming: await settings.get(Settings.faceTimeIncomingHandoff)
    )

    let context = AppContext(
      storage: storage,
      readPath: readPath,
      shared: shared,
      transport: transport,
      additionalRouteGroups: additionalGroups,
      // Registered with every manifest below, so a tool is known to the manager because
      // a service declared it, not because this file lists it a second time.
      tools: ToolManager(
        alerts: shared.alerts,
        // The bundled copy stays a fallback rather than being removed: a build that
        // does ship binaries in `Contents/Resources/bin` keeps working, and an
        // offline first run has something to fall back to.
        bundledLocator: { BundledBinaries.path(for: $0) },
        logger: logger
      )
    )

    let registry = await makeRegistry(context: context, shared: shared, settings: settings)
    await context.finishWiring(
      registry: registry,
      handlers: buildHandlers(
        context: context,
        authMode: transport.authMode,
        codecs: transport.codecs,
        additionalGroups: additionalGroups,
        logSink: storage.logSink,
        logger: logger
      )
    )

    // Every tool any service declares, in one registry. Derived from the manifests so a
    // program the server can install is exactly a program some service said it needs,
    // and so a third-party connection method's binary is managed by the same code that
    // manages ngrok's, with no list here to add itself to.
    // Tools come from the manifests that survived validation, for the same reason: a tool
    // descriptor on a refused manifest is an instruction to download and run a program from
    // a manifest we have just declared invalid.
    await context.tools.register(
      BuiltInManifests.all.filter { !refusedServices.contains($0.id) }
    )

    // Look for copies already on this Mac BEFORE any service starts, because the answer
    // decides whether a connection method has a program at all. A scan that landed after
    // `ProxyService.start` would leave a user who HAS cloudflared looking at "Cloudflare is
    // selected but not installed", with a working tunnel only after a restart.
    //
    // It is cheap enough to wait for: a Mac with none of these installed spawns nothing,
    // because no candidate file exists to probe, and a Mac that has them re-probes only
    // when a binary's fingerprint has moved. The bound is here for the case neither of
    // those covers — a first run where a binary stalls in Gatekeeper assessment — and
    // carrying on without the answer is correct there: the scan is retried by
    // `ToolUpdateService`, and nothing here is wrong without it, only slower to notice.
    do {
      let tools = context.tools
      try await withTimeout(.seconds(5)) { await tools.scanForExistingCopies() }
    } catch {
      logger.warning(
        "Looking for programs already installed on this Mac did not finish in time",
        metadata: ["error": .string(String(describing: error))]
      )
    }

    await registerServices(in: registry, refusing: refusedServices)

    return RunningServer(
      context: context,
      logSink: storage.logSink,
      registry: registry,
      // Constructed here rather than inside `start()` so the whole graph is visible in
      // one place, and so a test can drive it without standing up a listener.
      propagation: makePropagation(
        settings: settings, registry: registry, context: context, shared: shared,
        passwordDigests: transport.passwordDigests
      ),
      handlers: await context.httpHandlers,
      routeGroups: additionalGroups,
      options: options,
      logger: logger
    )
  }
}
