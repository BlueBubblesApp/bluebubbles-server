//  ToolError
//  What can go wrong between "install this" and "here is a path".
//
//  Every case carries the thing a user would need in order to do something about it — the
//  architecture that has no build, the team that signed it instead, the two digests that
//  disagreed. "Installation failed" is the message this file exists to never produce.

import BBCore
import BBServiceKit
import Foundation

public enum ToolError: BBError, Equatable, CustomStringConvertible {

  case unknownTool(String)
  /// No build for anything this Mac can run.
  case noBuildForArchitecture(tool: String, host: ToolArchitecture, available: [ToolArchitecture])
  /// An Intel-only tool on an Apple Silicon Mac with no Rosetta.
  case rosettaRequired(tool: String)
  case releaseLookupFailed(tool: String, reason: String)
  /// The release exists but carries nothing matching the declared pattern.
  case assetNotFound(tool: String, pattern: String, available: [String])
  case downloadFailed(tool: String, url: String, reason: String)
  case checksumMissing(tool: String, asset: String)
  case checksumMismatch(tool: String, expected: String, actual: String)
  case unpackFailed(tool: String, reason: String)
  case executableNotFoundInArchive(tool: String, expected: String)
  case notSigned(tool: String)
  case signatureInvalid(tool: String, reason: String)
  /// A build signed by someone other than whoever signed what is already installed. This is
  /// the shape a supply-chain substitution takes, so it is refused rather than reported.
  case signatureTeamChanged(tool: String, pinned: String, found: String)
  case versionProbeFailed(tool: String, reason: String)
  case installFailed(tool: String, reason: String)
  case nothingToRevertTo(tool: String)
  case externalBinaryUnusable(path: String, reason: String)
  /// Two installs of the same tool at once.
  case busy(tool: String)

  public var description: String {
    switch self {
    case .unknownTool(let id):
      "No program called '\(id)' is declared by anything installed."
    case .noBuildForArchitecture(let tool, let host, let available):
      "\(tool) has no build for \(host.displayName). It publishes: "
        + "\(available.map(\.displayName).joined(separator: ", "))."
    case .rosettaRequired(let tool):
      "\(tool) only publishes an Intel build, and this Mac cannot run Intel programs "
        + "until Rosetta is installed."
    case .releaseLookupFailed(let tool, let reason):
      "Could not find out which version of \(tool) is current: \(reason)"
    case .assetNotFound(let tool, let pattern, let available):
      "\(tool)'s latest release has no download matching '\(pattern)'. It contains: "
        + "\(available.prefix(8).joined(separator: ", "))."
    case .downloadFailed(let tool, let url, let reason):
      "Downloading \(tool) from \(url) failed: \(reason)"
    case .checksumMissing(let tool, let asset):
      "\(tool) publishes checksums, but none for '\(asset)'."
    case .checksumMismatch(let tool, let expected, let actual):
      "The \(tool) download does not match its published checksum "
        + "(expected \(expected.prefix(16))…, got \(actual.prefix(16))…). It was discarded."
    case .unpackFailed(let tool, let reason):
      "Could not unpack the \(tool) download: \(reason)"
    case .executableNotFoundInArchive(let tool, let expected):
      "The \(tool) download does not contain '\(expected)'."
    case .notSigned(let tool):
      "The \(tool) download carries no code signature, so there is no way to tell who "
        + "built it. It was discarded."
    case .signatureInvalid(let tool, let reason):
      "The \(tool) download's code signature is not valid: \(reason)"
    case .signatureTeamChanged(let tool, let pinned, let found):
      "This \(tool) build is signed by \(found), but the copy already installed was "
        + "signed by \(pinned). It was refused — install it again from scratch if the "
        + "vendor really did change signing identity."
    case .versionProbeFailed(let tool, let reason):
      "The downloaded \(tool) would not run on this Mac: \(reason)"
    case .installFailed(let tool, let reason):
      "Could not finish installing \(tool): \(reason)"
    case .nothingToRevertTo(let tool):
      "There is no earlier version of \(tool) to go back to."
    case .externalBinaryUnusable(let path, let reason):
      "\(path) cannot be used: \(reason)"
    case .busy(let tool):
      "\(tool) is already being installed."
    }
  }

  /// The stable code for a diagnostic report, so an issue thread can be searched by it.
  public var code: String {
    switch self {
    case .unknownTool: "tool.unknown"
    case .noBuildForArchitecture: "tool.no_build_for_arch"
    case .rosettaRequired: "tool.rosetta_required"
    case .releaseLookupFailed: "tool.release_lookup_failed"
    case .assetNotFound: "tool.asset_not_found"
    case .downloadFailed: "tool.download_failed"
    case .checksumMissing: "tool.checksum_missing"
    case .checksumMismatch: "tool.checksum_mismatch"
    case .unpackFailed: "tool.unpack_failed"
    case .executableNotFoundInArchive: "tool.executable_missing"
    case .notSigned: "tool.not_signed"
    case .signatureInvalid: "tool.signature_invalid"
    case .signatureTeamChanged: "tool.signature_team_changed"
    case .versionProbeFailed: "tool.version_probe_failed"
    case .installFailed: "tool.install_failed"
    case .nothingToRevertTo: "tool.nothing_to_revert_to"
    case .externalBinaryUnusable: "tool.external_binary_unusable"
    case .busy: "tool.busy"
    }
  }
}

extension ToolError {
  /// `code` was already here, in exactly this protocol's shape, before anything conformed.
  public var domain: String { "Tools" }

  /// Installing a tunnel binary is something the user asked for and is watching, so a
  /// failure is theirs to see. `busy` is not a failure — it is two requests overlapping.
  public var isUserFacing: Bool {
    if case .busy = self { return false }
    return true
  }

  public var title: String {
    switch self {
    case .notSigned, .signatureInvalid, .signatureTeamChanged, .checksumMismatch,
      .checksumMissing:
      "A downloaded program failed its safety checks"
    case .noBuildForArchitecture, .rosettaRequired:
      "No build for this Mac"
    case .busy:
      "That tool is busy"
    default:
      "Could not install the tool"
    }
  }

  /// Every case already writes a sentence a person can act on.
  public var body: String { description }

  public var severity: Severity {
    switch self {
    // A binary that fails signature or checksum verification is not a routine install
    // failure — it is a program that is not what it claims to be.
    case .notSigned, .signatureInvalid, .signatureTeamChanged, .checksumMismatch: .critical
    case .busy: .info
    default: .error
    }
  }
}
