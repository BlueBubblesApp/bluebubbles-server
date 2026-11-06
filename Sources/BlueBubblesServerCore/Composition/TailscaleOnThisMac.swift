//  TailscaleOnThisMac
//  The app's door to "is there a Tailscale already running here, and is it publishing this
//  server?", answered in terms the app can use without linking the proxy module.
//
//  The probe is `ExistingTailscale` in `BBProxy`, which knows the CLI and the documents it
//  prints. This file decides only two things: which `tailscale` program asks, and what of the
//  answer the app is handed. The app gets the addresses that already reach THIS server, not
//  the serve config: which mounts count is a rule about clients (a root mount, forwarding to
//  our port) and it is made once, here, rather than by every screen that shows one.

import BBBuiltIns
import BBProxy
import BBTooling
import Foundation

/// A Tailscale somebody else runs on this Mac, as the Tailscale page needs to know it.
public enum TailscaleOnThisMac: Sendable, Equatable {
  /// Nothing answered on the system socket, or there was no `tailscale` program to ask with.
  case absent
  /// A daemon is up and its node is not signed in.
  case signedOut
  /// A signed-in node.
  case running(dnsName: String?, publishing: Publishing)

  public enum Publishing: Sendable, Equatable {
    /// Its serve config could not be read. Not "nothing", which would be a claim.
    case unknown
    /// The addresses at which it forwards to this server: none, one, or several.
    case addresses([String])
  }
}

/// Asks, through the tool manager's `tailscale`.
public struct TailscaleOnThisMacLookup: Sendable {

  private let tools: ToolManager

  init(tools: ToolManager) { self.tools = tools }

  /// - Parameters:
  ///   - serverPort: the port this server listens on, which a serve mount has to forward to
  ///     for its address to be this server's.
  ///   - originUsesTLS: whether that listener speaks TLS, which the mount's scheme has to
  ///     agree with for the address to work.
  public func inspect(
    serverPort: Int, originUsesTLS: Bool
  ) async throws(CancellationError) -> TailscaleOnThisMac {
    guard let cli = await cliPath() else { return .absent }
    switch try await ExistingTailscale.inspect(cliPath: cli) {
    case .none:
      return .absent
    case .notRunning:
      return .signedOut
    case .running(let node):
      let publishing: TailscaleOnThisMac.Publishing =
        node.serve.map {
          .addresses(
            $0.rootHandlers(forwardingToLoopbackPort: serverPort, originUsesTLS: originUsesTLS)
              .map(\.publishedAddress))
        } ?? .unknown
      return .running(dnsName: node.dnsName, publishing: publishing)
    }
  }

  /// The CLI to ask with: whichever copy a service would be handed, and failing that the
  /// one beside a copy the scan found and did not adopt.
  ///
  /// The second matters for exactly the person this exists for. A MacPorts `tailscaled`
  /// outside the range this server drives is not handed to the connection method, but its
  /// `tailscale` reads its own daemon's status perfectly well, and reading is all this does.
  private func cliPath() async -> String? {
    let id = BuiltInTools.tailscale.id
    if let path = await tools.companionExecutablePath(for: id, named: "tailscale") {
      return path
    }
    guard let found = await tools.status(of: id)?.state.discovered?.executablePath else {
      return nil
    }
    let beside = (found as NSString).deletingLastPathComponent + "/tailscale"
    return FileManager.default.isExecutableFile(atPath: beside) ? beside : nil
  }
}
