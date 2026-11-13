//  LicenseAuditing
//  What the licence runtime tells an auditor, in its own vocabulary.
//
//  The runtime is where these facts are KNOWN: it is the only thing that evaluates the stored
//  state, exchanges the key, records a revocation or clears the licence. It may not import the
//  audit module, so it describes each fact here and the composition root translates it into an
//  audit record (`AuditWiring.swift`). The same shape as `AuthenticationAuditing` in `BBAuth`
//  and for the same reason.
//
//  Nothing here carries the key, the token string or the machine fingerprint. A status is a
//  name, a token is its decoded claims, and the bridge chooses which of those a record keeps.

import BBLicense
import Foundation

/// One thing the licence runtime did, or found.
public enum LicenseAuditEvent: Sendable, Equatable {
  /// The evaluated status moved. `previous` is nil for the first evaluation of a run, which
  /// is reported only when it says something: a run that primes to "no licence" is silent.
  case statusChanged(previous: LicenseStatus?, current: LicenseStatus)
  /// The issuer answered an exchange with a token, decoded. Says nothing about whether that
  /// token entitles this server now; `statusChanged` does.
  case refreshed(EntitlementToken)
  /// An exchange did not produce a token. The entitlement in hand is untouched.
  case refreshFailed(reason: String)
  /// The issuer reports the licence disabled. Reported once per revocation, not once per
  /// exchange that repeats it.
  case revoked
  /// The licence was removed from this Mac. `previous` is the status it held.
  case removed(previous: LicenseStatus)
}

public protocol LicenseAuditing: Sendable {
  /// Returns at once; the implementation decides what, if anything, to keep.
  func record(_ event: LicenseAuditEvent)
}
