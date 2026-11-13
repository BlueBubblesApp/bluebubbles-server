//  SystemIntegrity
//  Which of System Integrity Protection's protections this Mac enforces.
//
//  SIP is not one switch. `csrutil enable --without debug` leaves a Mac whose `csrutil status`
//  says neither enabled nor disabled, so the probe reads each protection and a page can say which
//  are still on.
//
//  **Only all five on refuses the Private API.** Nobody here has measured which subset injection
//  needs, and people run subsets that work for them, so refusing part-way would be a guess that
//  breaks a working setup. A partial configuration is let through and gets a recommendation
//  (`PrivateAPIPrerequisite.partial`), and if its helper cannot load, the status card says so.
//
//  Only the five protections `csrutil enable --without` can name are modelled, because those are
//  what a person can act on and what the page can tell them to change. The other bits are not
//  the answer on any Mac: `csrutil disable` left bits 4 and 7 to 15 unset on 27.0.1 (measured:
//  `csr_get_active_config` read 0x6f), so requiring every bit would refuse a fully disabled Mac.

import Foundation

public enum SIPProtection: CaseIterable, Hashable, Sendable {
  case kextSigning
  case filesystem
  case debugging
  case dtrace
  case nvram

  /// What `csrutil status` calls it on a custom configuration, so a person who runs it finds the
  /// same words.
  public var title: String {
    switch self {
    case .kextSigning: "Kext Signing"
    case .filesystem: "Filesystem Protections"
    case .debugging: "Debugging Restrictions"
    case .dtrace: "DTrace Restrictions"
    case .nvram: "NVRAM Protections"
    }
  }

  /// The bit `csr_check` is asked about, from XNU's `bsd/sys/csr.h`: `CSR_ALLOW_UNTRUSTED_KEXTS`,
  /// `CSR_ALLOW_UNRESTRICTED_FS`, `CSR_ALLOW_TASK_FOR_PID`, `CSR_ALLOW_UNRESTRICTED_DTRACE` and
  /// `CSR_ALLOW_UNRESTRICTED_NVRAM`.
  var csrFlag: UInt32 {
    switch self {
    case .kextSigning: 1 << 0
    case .filesystem: 1 << 1
    case .debugging: 1 << 2
    case .dtrace: 1 << 5
    case .nvram: 1 << 6
    }
  }
}

/// What SIP enforces on this boot. One process only ever sees one answer: `csrutil` runs in
/// Recovery, and what it sets applies at the next boot.
public struct SIPConfiguration: Equatable, Sendable {

  public let enforced: Set<SIPProtection>

  public init(enforced: Set<SIPProtection>) { self.enforced = enforced }

  public static let fullyEnabled = SIPConfiguration(enforced: Set(SIPProtection.allCases))
  public static let fullyDisabled = SIPConfiguration(enforced: [])

  /// Reads each protection.
  ///
  /// - Parameter isAllowed: `csr_check` for one flag, true when SIP is NOT enforcing it.
  init(isAllowed: (UInt32) -> Bool) {
    enforced = Set(SIPProtection.allCases.filter { !isAllowed($0.csrFlag) })
  }

  /// Reads `csrutil status`, or nil when the output does not say.
  ///
  /// A protection's own line wins over the summary, because a custom configuration's summary
  /// does not describe it. Lines that do not cover every protection fall back to the summary,
  /// where "enabled (Custom Configuration)" reads as everything enforced: the direction that
  /// sends somebody to check rather than promising what nobody read.
  init?(csrutilStatus: String) {
    let lines = csrutilStatus.lowercased().split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    func isEnforced(_ label: String) -> Bool? {
      let prefix = label.lowercased() + ":"
      guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
      let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("disabled") { return false }
      if value.hasPrefix("enabled") { return true }
      return nil
    }

    let answers = SIPProtection.allCases.compactMap { protection in
      isEnforced(protection.title).map { (protection, $0) }
    }
    if answers.count == SIPProtection.allCases.count {
      enforced = Set(answers.filter(\.1).map(\.0))
    } else if let everything = isEnforced("System Integrity Protection status") {
      enforced = everything ? Set(SIPProtection.allCases) : []
    } else {
      return nil
    }
  }

  /// What is still on, in a stable order for a sentence.
  public var stillEnforced: [SIPProtection] {
    SIPProtection.allCases.filter(enforced.contains)
  }

  public var isFullyEnabled: Bool { enforced.count == SIPProtection.allCases.count }

  /// The answer the permission list and the start gate read. Granted means something is off, so
  /// a partial configuration can try. See the header.
  var permissionStatus: PermissionStatus { isFullyEnabled ? .denied : .granted }
}
