//  PermissionsMonitorService
//  Starts first, because everything else's permission gate reads from it.

import BBBuiltIns
import BBInterfaces
import BBServiceKit
import BBSystem

/// Starts first, because everything else's permission gate reads from it.
actor PermissionsMonitorService: Service {
  static let manifest = BuiltInManifests.permissions
  /// Never worth restarting: a failure here is a failure to read system state, and
  /// retrying immediately would just fail the same way.
  static let restartPolicy = RestartPolicy.never

  /// The one thing this service touches, rather than the container that holds it.
  typealias Host = any PermissionsProviding

  private let permissions: PermissionsService

  init(host: any PermissionsProviding) {
    self.permissions = host.permissions
  }

  func start() async throws {
    await permissions.checkAll()
    await permissions.startMonitoring()
  }

  func stop() async {
    await permissions.stopMonitoring()
  }

  var health: ServiceHealth {
    get async {
      await permissions.requiredPermissionsSatisfied()
        ? .running
        : .degraded(reason: "a required permission is missing")
    }
  }
}
