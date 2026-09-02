//  PermissionsMonitorService
//  Starts first, because everything else's permission gate reads from it.

import BBServiceKit

/// Starts first, because everything else's permission gate reads from it.
final class PermissionsMonitorService: ContextualService {
  static let manifest = BuiltInManifests.permissions
  /// Never worth restarting: a failure here is a failure to read system state, and
  /// retrying immediately would just fail the same way.
  static let restartPolicy = RestartPolicy.never

  let context: AppContext

  init(host: AppContext) {
    self.context = host
  }

  func start() async throws {
    await context.permissions.checkAll()
    await context.permissions.startMonitoring()
  }

  func stop() async {
    await context.permissions.stopMonitoring()
  }

  var health: ServiceHealth {
    get async {
      await context.permissions.requiredPermissionsSatisfied()
        ? .running
        : .degraded(reason: "a required permission is missing")
    }
  }
}
