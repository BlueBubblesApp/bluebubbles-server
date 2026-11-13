//  TailscaleHandoffTests
//  What the Tailscale page offers someone whose Mac already runs Tailscale of its own.
//
//  The rule that matters is the one about filling the address in: only when there is exactly
//  one. A guessed address is published to every client with nothing saying it was guessed.

import BlueBubblesServerCore
import Testing

@testable import BlueBubblesApp

@Suite("Handing Tailscale to Custom URL")
struct TailscaleHandoffTests {

  private static let machine = "node.example.ts.net"

  private func handoff(_ found: TailscaleOnThisMac, tls: Bool = false) -> TailscaleHandoff {
    TailscaleHandoff(found, serverPort: 1234, originUsesTLS: tls)
  }

  @Test("No Tailscale, or one that is not signed in, draws nothing")
  func nothingToSay() {
    #expect(handoff(.absent) == .nothing)
    #expect(handoff(.signedOut) == .nothing)
  }

  @Test("Exactly one address that reaches this server is offered as it is")
  func oneAddress() {
    let answer = handoff(
      .running(dnsName: Self.machine, publishing: .addresses(["https://\(Self.machine)"])))
    #expect(answer == .publishedAt(machine: Self.machine, address: "https://\(Self.machine)"))
    #expect(answer.offeredAddresses == ["https://\(Self.machine)"])
  }

  @Test("Several addresses are each offered, and none is chosen for the person")
  func severalAddresses() {
    let addresses = ["https://\(Self.machine)", "https://\(Self.machine):8443"]
    let answer = handoff(.running(dnsName: Self.machine, publishing: .addresses(addresses)))
    #expect(answer == .publishedAtSeveral(machine: Self.machine, addresses: addresses))
    #expect(answer.offeredAddresses == addresses)
  }

  @Test("A node that does not publish this server offers the command that would, and no address")
  func notPublishing() {
    for publishing in [TailscaleOnThisMac.Publishing.addresses([]), .unknown] {
      let answer = handoff(.running(dnsName: Self.machine, publishing: publishing))
      #expect(
        answer
          == .notPublishing(
            machine: Self.machine, serveCommand: "tailscale serve --bg http://127.0.0.1:1234"))
      #expect(answer.offeredAddresses.isEmpty)
    }
  }

  @Test("The command forwards in the protocol this server listens in")
  func commandFollowsTLS() {
    #expect(
      TailscaleHandoff.serveCommand(port: 1234, originUsesTLS: true)
        == "tailscale serve --bg https+insecure://127.0.0.1:1234")
  }
}
