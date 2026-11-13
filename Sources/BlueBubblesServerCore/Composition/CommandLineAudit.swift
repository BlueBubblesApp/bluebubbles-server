//  CommandLineAudit
//  What a command that changes this server and exits leaves in the audit log.
//
//  `--clear-blocklist`, `--migrate`, `--remove-legacy-credentials` and `--import` change blocks
//  and settings without building the server, and the recorder the audit log service arms
//  belongs to a built server. So they ran with nothing recorded: anyone with a shell could
//  clear the blocklist or rewrite the configuration and leave no trace in a log whose job is
//  to hold exactly that. A command now arms a recorder of its own when the audit log is
//  switched on, attaches the bridge the server uses for settings, and runs as the operator at
//  the command line, which is what `source = cli` means.
//
//  Switched off, it records nothing, as a server with the audit log off records nothing.

import BBAudit
import BBBuiltIns
import BBCore
import BBPersistence
import BBSettings

public struct CommandLineAudit: Sendable {

  /// Who a one-shot command acts as. Applied with `AuditContext.with` at the call site.
  public static let context = AuditContext(actor: .operator, source: .cli)

  /// Nil when the audit log is switched off.
  private let recorder: AuditRecorder?

  /// Arms a recorder over `database` if the audit log is switched on in `settings`, and tells
  /// the store about it so every setting the command writes is recorded.
  public static func begin(database: AppDatabase, settings: SettingsStore) async
    -> CommandLineAudit
  {
    guard await ServiceEnablement.isEnabled(BuiltInManifests.ID.auditLog, settings: settings)
    else { return CommandLineAudit(recorder: nil) }
    let recorder = AuditRecorder()
    await recorder.arm(store: AuditRepository(database: database))
    await settings.attachAuditObserver(AuditSettingsBridge(recorder: recorder))
    return CommandLineAudit(recorder: recorder)
  }

  /// `--clear-blocklist`, recorded as the server records a clear: as `blocks_cleared`.
  public func blocklistCleared(count: Int) {
    guard let recorder else { return }
    AuditAccessControlBridge(recorder: recorder).record(.blocksCleared(count: count))
  }

  /// Writes what was recorded. Called before the command exits, whether or not it succeeded.
  public func finish() async {
    await recorder?.disarm()
  }
}
