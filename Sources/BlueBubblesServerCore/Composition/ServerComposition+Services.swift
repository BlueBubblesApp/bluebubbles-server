//  ServerComposition+Services
//  The registry, every built-in service, and settings propagation.
//
//  The list of services is the one list here, and it is not an order: start order is
//  derived from each manifest's dependencies and stop order is its reverse, so a service
//  is added by registering it, never by placing it.

import BBAuth
import BBBuiltIns
import BBCore
import BBDiagnostics
import BBServiceKit
import BBSettings

extension ServerComposition {

  // MARK: - Registry

  static func makeRegistry(
    context: AppContext, shared: SharedServices, settings: SettingsStore
  ) async -> ServiceRegistry<AppContext> {
    let alerts = shared.alerts
    return ServiceRegistry(
      host: context,
      permissionCheck: await shared.permissions.permissionCheck(),
      // What the Integrations screen's switches actually DO: a write to `disabled_services`
      // reaches the registry here, so a webhook endpoint stops receiving events when it is
      // switched off rather than only losing its "enabled" tag.
      enablementCheck: { [settings] id in
        await ServiceEnablement.isEnabled(id, settings: settings)
      },
      enablementSettings: [Settings.disabledServicesKey],
      onAlert: { id, error in
        await alerts.raise(
          UserAlert(
            severity: .error,
            title: "\(id.rawValue) stopped working",
            body: DiagnosticText.sentence(for: error),
            source: "Services",
            dedupeKey: "service.\(id.rawValue)",
            // A live condition: on the next start the service either comes up or fails
            // again and says so, so the stale one must not greet the user as current.
            isDurable: false
          )
        )
      }
    )
  }

  /// Every service, registered. Order is DERIVED from each service's declared
  /// dependencies, not from the order they appear here.
  /// - Parameter refusing: services the manifest validator rejected. They are not
  ///   registered at all, rather than registered and gated: a service the registry does not
  ///   know about cannot be started by a settings change, a dependency, or a supervised
  ///   retry. This is the half that was missing, which made the validator advisory.
  static func registerServices(
    in registry: ServiceRegistry<AppContext>,
    refusing: Set<ServiceIdentifier> = []
  ) async {
    /// Registers unless the validator refused this service.
    ///
    /// Takes the projection the registry takes, rather than constraining `S.Host` to
    /// `AppContext`: services declare narrow hosts on purpose, and the conversion is only
    /// checkable where the concrete types are, which is the call site.
    func register<S: Service>(
      _ type: S.Type,
      from project: @escaping @Sendable (AppContext) -> S.Host
    ) async {
      guard !refusing.contains(S.manifest.id) else { return }
      await registry.register(type, from: project)
    }
    await register(PermissionsMonitorService.self) { $0 }
    await register(ContactsService.self) { $0 }
    await register(ChangeDetectionService.self) { $0 }
    // Beside the watcher because they read the same database, and independent of it because
    // they share nothing else: no cursor, no ordering, and deliberately no dependency, so a
    // watcher restart cannot discard a backfill in progress.
    await register(MessageSearchIndexService.self) { $0 }
    await register(HTTPService.self) { HTTPServiceHost($0) }
    await register(SocketService.self) { $0 }
    await register(PrivateAPIGatedService.self) { $0 }
    await register(PushDeliveryService.self) { $0 }
    await register(WebhookDeliveryService.self) { $0 }
    await register(NtfyDeliveryService.self) { $0 }
    await register(ScheduledMessageService.self) { $0 }
    // Six connection methods, one exclusive category: all register, and `canRun` lets
    // exactly the selected one through. This is what makes a third-party tunnel possible:
    // it joins a category rather than adding a case to an enum.
    await register(ProxyService<LANMethod>.self) { $0 }
    await register(ProxyService<DynamicDNSMethod>.self) { $0 }
    await register(ProxyService<NgrokMethod>.self) { $0 }
    await register(ProxyService<CloudflareMethod>.self) { $0 }
    await register(ProxyService<ZrokMethod>.self) { $0 }
    await register(ProxyService<TailscaleMethod>.self) { $0 }
    await register(SleepPreventionService.self) { $0 }
    await register(LaunchAtLoginService.self) { $0 }
    await register(ToolUpdateService.self) { $0 }
    await register(LicenseService.self) { $0 }
    await register(NetworkPathService.self) { $0 }
    await register(NetworkRecoveryService.self) { $0 }
    await register(AuditLogService.self) { $0 }
  }

  // MARK: - Settings propagation

  static func makePropagation(
    settings: SettingsStore,
    registry: ServiceRegistry<AppContext>,
    context: AppContext,
    shared: SharedServices,
    passwordDigests: PasswordDigestCache
  ) -> SettingsPropagation {
    let alerts = shared.alerts
    return SettingsPropagation(
      settings: settings, registry: registry, accessControl: shared.accessControl,
      // The tunnel writes `server_address` and this is what turns that write into
      // something clients hear about: a `new-server` frame, and a Firebase document
      // for the ones that are not connected.
      onServerAddressChanged: { [weak context] address in
        guard let lifecycle = await context?.lifecycle else { return }
        await lifecycle.announce(serverAddress: address)
      },
      // Saved, not yet in effect, and one click from being in effect. Deduplicated
      // on a fixed key so toggling one of these repeatedly leaves one standing
      // notice rather than a pile of identical ones.
      onRestartRequired: { [alerts] keys in
        let names = keys.map(Settings.label(forKey:)).sorted()
          .joined(separator: ", ")
        await alerts.raise(
          UserAlert(
            severity: .info,
            title: "Restart the server to apply this",
            body: "\(names) is saved, but the server reads it while starting "
              + "up. Restarting applies it; connected clients reconnect on "
              + "their own.",
            source: "settings",
            actions: [.restartServer],
            dedupeKey: "structural-setting-changed",
            // Restarting is exactly what clears this, so it must never survive one.
            isDurable: false
          )
        )
      },
      passwordDigests: passwordDigests
    )
  }
}
