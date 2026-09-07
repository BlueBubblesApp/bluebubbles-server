//  CodeSignature
//  Who actually built the thing we just downloaded.
//
//  A checksum cannot answer this. It proves the file matches what the release metadata said,
//  and the release metadata came down the same connection from the same host — whoever can
//  serve one can serve both, and a compromised release page hands out a matched pair. The code
//  signature is the only part of a download whose trust does not come from the download: it
//  chains to Apple's root, which is already on the machine.
//
//  So: the checksum detects corruption and a swapped file, and the signature identifies the
//  vendor. Both, where both exist, and `SignaturePolicy` says which are required.
//
//  Team-ID pinning is the check that matters most and is the least obvious. Verifying "signed
//  by someone with a Developer ID" on every update accepts a build signed by ANY of the
//  hundreds of thousands of Apple developer accounts. Verifying it is the same team that
//  signed what is already installed accepts only the vendor — and a change in that answer is
//  precisely the signal a supply-chain substitution gives off.

import Foundation
import Security

public struct CodeSignatureInfo: Sendable, Equatable {
  public let isSigned: Bool
  public let teamID: String?
  /// `Cloudflare, Inc.` — for showing a person, never for deciding anything.
  public let authority: String?

  public init(isSigned: Bool, teamID: String?, authority: String?) {
    self.isSigned = isSigned
    self.teamID = teamID
    self.authority = authority
  }
}

public enum CodeSignature {

  /// Reads and validates the signature on a file.
  ///
  /// Returns `isSigned: false` for an unsigned binary rather than throwing — that is a
  /// legitimate answer about a legitimate file (zrok ships unsigned), and whether it is
  /// acceptable is the policy's decision, not this function's. A signature that is present
  /// but BROKEN does throw: that is not a description of the file, it is tampering.
  public static func inspect(_ path: String, toolID: String) throws -> CodeSignatureInfo {
    var staticCode: SecStaticCode?
    let url = URL(fileURLWithPath: path) as CFURL
    let created = SecStaticCodeCreateWithPath(url, [], &staticCode)
    guard created == errSecSuccess, let staticCode else {
      throw ToolError.signatureInvalid(
        tool: toolID, reason: message(for: created)
      )
    }

    // Validity first. `.checkAllArchitectures` matters for a universal binary: without it
    // only the slice matching this process is checked, and under Rosetta that is the wrong
    // one.
    let validity = SecStaticCodeCheckValidity(
      staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil
    )
    switch validity {
    case errSecSuccess:
      break
    case errSecCSUnsigned:
      return CodeSignatureInfo(isSigned: false, teamID: nil, authority: nil)
    default:
      throw ToolError.signatureInvalid(tool: toolID, reason: message(for: validity))
    }

    var information: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
      let details = information as? [String: Any]
    else {
      return CodeSignatureInfo(isSigned: true, teamID: nil, authority: nil)
    }

    let teamID = details[kSecCodeInfoTeamIdentifier as String] as? String
    let authority = (details[kSecCodeInfoCertificates as String] as? [SecCertificate])
      .flatMap(\.first)
      .flatMap { certificate -> String? in
        SecCertificateCopySubjectSummary(certificate) as String?
      }
    return CodeSignatureInfo(isSigned: true, teamID: teamID, authority: authority)
  }

  /// Whether the file satisfies a Developer ID requirement, optionally pinned to a team.
  ///
  /// Evaluated by the system's own requirement language rather than by comparing the strings
  /// this file already read. That is deliberate: the requirement checks the certificate
  /// CHAIN — Apple's anchor, the Developer ID CA, the leaf's team — and a hand-rolled
  /// comparison of a team identifier read out of a dictionary checks none of it.
  public static func satisfiesDeveloperID(
    _ path: String, teamID: String?, toolID: String
  ) throws {
    // `anchor apple generic` plus the Developer ID marker OIDs. This is the same
    // requirement Gatekeeper applies to a downloaded application.
    var requirementText =
      "anchor apple generic and "
      + "certificate 1[field.1.2.840.113635.100.6.2.6] exists and "
      + "certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    if let teamID {
      requirementText += " and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(
        requirementText as CFString, [], &requirement
      ) == errSecSuccess, let requirement
    else {
      throw ToolError.signatureInvalid(
        tool: toolID, reason: "the signing requirement could not be built"
      )
    }

    var staticCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(
        URL(fileURLWithPath: path) as CFURL, [], &staticCode
      ) == errSecSuccess, let staticCode
    else {
      throw ToolError.signatureInvalid(tool: toolID, reason: "the file could not be read")
    }

    let result = SecStaticCodeCheckValidity(
      staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement
    )
    guard result == errSecSuccess else {
      throw ToolError.signatureInvalid(tool: toolID, reason: message(for: result))
    }
  }

  private static func message(for status: OSStatus) -> String {
    SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
  }
}
