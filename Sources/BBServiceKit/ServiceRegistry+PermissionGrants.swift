//  ServiceRegistry+PermissionGrants
//  A macOS permission granted while the server runs reaches the services that declared it.
//
//  Its own file because it is one decision: a service refused at its gate starts from its
//  manifest's declaration when the grant arrives, without a relaunch.

import BBCore
import BBSettings
import Foundation
import Logging

extension ServiceRegistry {

  // MARK: - Permission grants

  /// Tells the services that declare these permissions that macOS has now granted them.
  ///
  /// macOS gives no notification for a TCC change, so `PermissionsMonitorService` follows the
  /// probes and reports each grant here. Without this a service refused at its gate stays
  /// refused until a settings write or a relaunch happens to try it again, and someone who
  /// grants Full Disk Access sees nothing change.
  ///
  /// Two shapes, decided by whether there is an instance:
  ///
  /// - **No instance, and it declares one of these `.required`:** started. `performStart`
  ///   re-checks everything, so one still missing another permission, switched off or declined
  ///   by its gate stays inactive and says so.
  /// - **Running, and a `PermissionRespondingService`:** told, in its lane.
  ///
  /// A service with no instance that declares one only as `.recommended` or `.feature` is left
  /// alone: the permission is not what is stopping it. A restart is never ordered for a running
  /// service, because one that works without a permission has clients attached to lose.
  public func permissionsGranted(_ granted: Set<PermissionID>) async {
    guard !granted.isEmpty, !isStopped else { return }
    guard !isStarting else {
      deferredGrants.formUnion(granted)
      return
    }
    for id in startOrder {
      guard !isStopped, let registration = registrations[id] else { continue }
      let declared = registration.manifest.permissions.map(\.id).filter(granted.contains)
      guard !declared.isEmpty else { continue }

      if instances[id] == nil {
        if !Set(registration.requiredPermissions).isDisjoint(with: declared) {
          await start(id)
        }
      } else {
        await serialized(id) { await self.deliver(declared, to: id) }
      }
    }
  }

  /// Read inside the lane, so an instance stopped while this waited is not told.
  private func deliver(_ permissions: [PermissionID], to id: ServiceIdentifier) async {
    guard let responding = instances[id] as? any PermissionRespondingService else { return }
    for permission in permissions {
      await responding.permissionGranted(permission)
    }
  }
}
