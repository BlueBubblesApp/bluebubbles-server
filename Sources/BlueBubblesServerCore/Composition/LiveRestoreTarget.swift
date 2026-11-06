//  LiveRestoreTarget
//  What an import reaches in a server running over the storage it writes.
//
//  The importer writes the record sections to the tables, and a running server keeps copies
//  of two of them. `ContactIndex` keeps five minutes of answered lookups, so names would
//  resolve from the old address book until each entry lapsed: it is told the moment the
//  contacts section is written. `AccessControlService` holds both lists for the life of the
//  process and rewrites each table from memory on its next change, so a table written
//  beneath it is overwritten by the next block: it is handed to the importer, which writes
//  the section through it. `RestoreTarget` is why those two differ.
//
//  Restored Firebase credentials restart the push service, through the lifecycle the in-app
//  Firebase import restarts it through (`reloadPush` in `AppContext.pushInterface`, which
//  is `ServerLifecycle.restartPush`), because push reads its credentials once, when it
//  starts, and a server that started without any has no push service to reload at all. A
//  restored TLS certificate restarts nothing, as the Security page's import restarts
//  nothing: the listener reads its material at start.
//
//  **Held by `Storage`, not by the composition.** The importer is built from storage, by
//  the app and the CLI alike, with or without a server running over it; a server is built
//  from the same storage later, if at all. So the storage carries this, and the composition
//  attaches what it builds as it builds it. The references are weak: a stopped server's
//  index and controller are not this object's to keep alive, and with nothing attached the
//  importer writes the tables itself, which is right for a server that is not running.

import BBAuth
import BBContacts
import BBExport
import Foundation

public actor LiveRestoreTarget: RestoreTarget {

  private weak var contacts: ContactIndex?
  private weak var accessControl: AccessControlService?
  private weak var lifecycle: ServerLifecycle?

  public init() {}

  /// What the composition built over this storage. Called once per build.
  func attach(contacts: ContactIndex, accessControl: AccessControlService) {
    self.contacts = contacts
    self.accessControl = accessControl
  }

  /// The running server's lifecycle, once it is wired. Called once per build.
  func attach(lifecycle: ServerLifecycle) {
    self.lifecycle = lifecycle
  }

  public func runningAccessControl() -> AccessControlService? { accessControl }

  public func sectionWasRestored(_ section: ExportSection) async {
    switch section {
    case .contacts:
      await contacts?.invalidateCache()
    case .firebaseCredentials:
      await lifecycle?.restartPush()
    case .settings, .webhooks, .scheduledMessages, .devices, .accessControl, .clientBackups,
      .secrets, .tlsCertificate:
      // Nothing running keeps a copy of these that a restore has to reach now. Access
      // control is written through the controller (`runningAccessControl`), so it is
      // already current by the time this is called; the certificate is read at the next
      // start, as the header says. Exhaustive rather than `default`, so a new section has
      // to answer.
      break
    }
  }
}
