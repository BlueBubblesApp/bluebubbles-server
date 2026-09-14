//  TailscaleStatus
//  The parts of `tailscale status --json` this server reads.
//
//  Part of the Tailscale connection method; see `TailscaleTunnel.swift` for the design.

import BBCore
import BBServiceKit
import Foundation
import Logging

/// The parts of `tailscale status --json` this server reads.
///
/// Decoded by hand from a document whose shape Tailscale marks "subject to change", for the
/// same reason `ZrokEnvironment` decodes zrok's overview by hand: a `Codable` model of the
/// whole thing would fail on every key they add, and five values are all that matter here.
public struct TailscaleStatus: Sendable, Equatable {
  /// `NeedsLogin`, `NeedsMachineAuth`, `Stopped`, `Starting`, `Running`, or `NoState`.
  public let backendState: String
  /// The browser link that signs this node in, while `NeedsLogin`.
  public let authURL: URL?
  /// This node's MagicDNS name, without the trailing dot Tailscale reports it with.
  ///
  /// ASSIGNED by the control plane, and so a step behind `hostName` after a rename: the
  /// daemon reports the new machine name at once and the new DNS name only when the next
  /// network map arrives. See `TailscaleCLI.waitForMachineName`.
  public let dnsName: String?
  /// The machine name the daemon is configured with: `--hostname` as applied.
  public let hostName: String?
  /// The node capabilities the tailnet grants: `https` and `funnel` are the two consulted.
  public let capabilities: Set<String>

  public init(
    backendState: String, authURL: URL? = nil, dnsName: String? = nil,
    hostName: String? = nil, capabilities: Set<String> = []
  ) {
    self.backendState = backendState
    self.authURL = authURL
    self.dnsName = dnsName
    self.hostName = hostName
    self.capabilities = capabilities
  }

  public var isRunning: Bool { backendState == "Running" }
  /// Between states: the backend has not started, or is connecting to control. Not a
  /// failure and not a step for a person; the answer is to ask again in a moment.
  public var isTransitional: Bool { backendState == "NoState" || backendState == "Starting" }
  /// The first label of the DNS name: the machine name as the tailnet has it.
  public var assignedMachineName: String? {
    dnsName?.split(separator: ".").first.map(String.init)
  }
  public var needsLogin: Bool { backendState == "NeedsLogin" }
  public var needsMachineAuth: Bool { backendState == "NeedsMachineAuth" }
  /// Tailscale's `nodecap.HTTPS` and `nodecap.Funnel`, as they appear in `Self.CapMap`.
  public var hasHTTPS: Bool { capabilities.contains("https") }
  public var hasFunnel: Bool { capabilities.contains("funnel") }

  public static func parse(_ text: String) -> TailscaleStatus? {
    // Found rather than assumed to start at byte zero, in case a version prints a warning
    // line first.
    guard let start = text.firstIndex(of: "{"),
      let data = String(text[start...]).data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let state = object["BackendState"] as? String
    else { return nil }

    let selfNode = object["Self"] as? [String: Any] ?? [:]
    let dnsName = (selfNode["DNSName"] as? String).flatMap { name -> String? in
      let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
      return trimmed.isEmpty ? nil : trimmed
    }
    let capabilities = Set((selfNode["CapMap"] as? [String: Any])?.keys.map { $0 } ?? [])
    let authURL = (object["AuthURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    let hostName = (selfNode["HostName"] as? String).flatMap { $0.isEmpty ? nil : $0 }

    return TailscaleStatus(
      backendState: state, authURL: authURL, dnsName: dnsName, hostName: hostName,
      capabilities: capabilities
    )
  }
}
