//  OperatorAttribution
//  The person at the Mac, named where they act.
//
//  The server runs in this process, and a setting saved from a form, a webhook added, a client
//  unblocked all reach it as plain calls. The audit log attributes what it records to the
//  actor of the work in flight (`AuditContext`), and work nothing named is recorded as
//  `unattributed` rather than blamed on anyone. So every place the app changes the server's
//  state runs that change inside `asOperator`, which is what makes the record say "Operator,
//  through the app" and not "nobody knows".
//
//  `OperatorAttributionPolicyTests` scans this module for a write to the settings store, the
//  access controller, the webhook or schedule interfaces that is not inside one, and fails
//  the build on it. A new screen that forgets is a test failure, not a row that says nobody.
//
//  See `Sources/BBCore/AuditContext.swift` and `docs/AUDIT_LOG.md`.

import BBCore

/// Runs `body` as the person at the Mac, through the app's window.
///
/// On the caller's executor: wrapping a view's main-actor work does not send it anywhere.
/// Spelled twice for the reason `AuditContext.with` gives.
#if compiler(>=6.3)
  nonisolated(nonsending) func asOperator<T>(
    _ body: nonisolated(nonsending) () async throws -> T
  ) async rethrows -> T {
    try await AuditContext.with(AuditContext(actor: .operator, source: .app), body)
  }
#else
  func asOperator<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
  ) async rethrows -> T {
    try await AuditContext.with(
      AuditContext(actor: .operator, source: .app), isolation: isolation, body)
  }
#endif
