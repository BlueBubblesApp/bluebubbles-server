//  TLSTests
//  HTTPS and wss, on one port, from one certificate.
//
//  `use_custom_certificate` had been a setting since the migration began and did nothing:
//  `CertificateAuthority` could generate a certificate, nothing consumed it, and the listener
//  bound plain HTTP unconditionally. A user who turned it on got an unencrypted server and no
//  indication that anything had failed: the worst possible outcome for a security setting,
//  because it produces false confidence rather than a visible error.
//
//  These bind a real port with a real certificate and speak real TLS to it, because the
//  failure mode being guarded against is precisely "it looks configured and is not".

import BBAuth
import BBSettings
import BBSocketIO
import BBSystem
import Foundation
import Hummingbird
import NIOCore
import NIOPosix
import NIOSSL
import Testing

@testable import BBHTTPAPI
@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("TLS", .serialized)
struct TLSTests {

  private static let password = "hunter2hunter2"

  /// Accepts the self-signed certificate under test.
  ///
  /// A test that disabled TLS verification entirely would pass against a server serving
  /// plaintext, which is the one thing being checked, so the delegate confirms a
  /// certificate was actually presented before trusting it.
  private final class TrustingDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private(set) var sawServerTrust = false

    func urlSession(
      _ session: URLSession,
      didReceive challenge: URLAuthenticationChallenge,
      completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
      guard let trust = challenge.protectionSpace.serverTrust else {
        completionHandler(.performDefaultHandling, nil)
        return
      }
      sawServerTrust = true
      completionHandler(.useCredential, URLCredential(trust: trust))
    }
  }

  private func material() throws -> CertificateStore.Material {
    let generated = try CertificateAuthority.selfSigned(
      hostnames: ["localhost"], addresses: ["127.0.0.1"]
    )
    return CertificateStore.Material(
      certificatePEM: generated.certificatePEM,
      privateKeyPEM: generated.privateKeyPEM
    )
  }

  private func withServer(
    tls: CertificateStore.Material?,
    _ body: (Int, SocketServer) async throws -> Void
  ) async throws {
    let sockets = TestSocketStack(password: Self.password)
    try await TestHTTPServer.run(
      registry: TestHTTPServer.registry(.generalPing) { _ in .data(.string("pong")) },
      authentication: .password(Self.password),
      sockets: sockets,
      tls: tls
    ) { port in
      try await body(port, sockets.server)
    }
  }

  // MARK: - Configuration

  @Test("A generated certificate produces a usable TLS configuration")
  func certificateBuildsAConfiguration() throws {
    // NIOSSL is where a subtly wrong PEM surfaces, and its error is opaque, so this is
    // checked before anything tries to bind with it.
    let configuration = try HTTPListener.tlsConfiguration(from: try material())
    #expect(!configuration.certificateChain.isEmpty)
    // The server presents a certificate; it does not demand one. Requiring client
    // certificates would lock out every existing client.
    #expect(configuration.certificateVerification == .none)
  }

  @Test("A certificate chain with intermediates is loaded whole")
  func chainIsLoadedWhole() throws {
    // A real CA issues a leaf plus intermediates, concatenated. Serving only the leaf is
    // the most common TLS complaint there is: it works in a browser that cached the
    // intermediate and fails on a phone that did not.
    let first = try CertificateAuthority.selfSigned(hostnames: ["a.example.com"])
    let second = try CertificateAuthority.selfSigned(hostnames: ["b.example.com"])
    let chained = CertificateStore.Material(
      certificatePEM: first.certificatePEM + "\n" + second.certificatePEM,
      privateKeyPEM: first.privateKeyPEM
    )
    let configuration = try HTTPListener.tlsConfiguration(from: chained)
    #expect(configuration.certificateChain.count == 2)
  }

  @Test("A malformed certificate is rejected rather than downgraded")
  func malformedCertificateIsRejected() throws {
    // The rule that matters: someone who configured TLS believes their traffic is
    // encrypted. Falling back to plaintext and logging a warning is worse than not
    // starting, because it produces confidence rather than an error.
    let broken = CertificateStore.Material(
      certificatePEM: "-----BEGIN CERTIFICATE-----\nnot base64\n-----END CERTIFICATE-----",
      privateKeyPEM: try material().privateKeyPEM
    )
    #expect(throws: (any Error).self) {
      _ = try HTTPListener.tlsConfiguration(from: broken)
    }
  }

  // MARK: - Over the wire

  @Test("The API is served over HTTPS")
  func apiIsServedOverTLS() async throws {
    try await withServer(tls: try material()) { port, _ in
      let delegate = TrustingDelegate()
      let session = URLSession(
        configuration: .ephemeral, delegate: delegate, delegateQueue: nil
      )
      defer { session.finishTasksAndInvalidate() }

      let url = URL(
        string: "https://localhost:\(port)/api/v1/ping?password=\(Self.password)"
      )!
      let (_, response) = try await session.data(for: Self.closing(url))

      #expect((response as? HTTPURLResponse)?.statusCode == 200)
      // The assertion that separates "served over TLS" from "served in plaintext and
      // the client did not mind": a certificate was actually presented.
      #expect(delegate.sawServerTrust, "no certificate was presented; this is not TLS")
    }
  }

  @Test("The socket is served over the same TLS as the API")
  func socketIsServedOverTLS() async throws {
    // One certificate, one port, both surfaces. There is deliberately no way to
    // configure an encrypted API with a plaintext socket beside it.
    try await withServer(tls: try material()) { port, _ in
      let delegate = TrustingDelegate()
      let session = URLSession(
        configuration: .ephemeral, delegate: delegate, delegateQueue: nil
      )
      defer { session.finishTasksAndInvalidate() }

      let url = URL(
        string: "https://localhost:\(port)/socket.io/"
          + "?EIO=4&transport=polling&password=\(Self.password)"
      )!
      let (data, response) = try await session.data(for: Self.closing(url))

      #expect((response as? HTTPURLResponse)?.statusCode == 200)
      #expect(String(decoding: data, as: UTF8.self).hasPrefix("0{"))
      #expect(delegate.sawServerTrust)
    }
  }

  /// A request that asks the server to close the connection once it has answered.
  ///
  /// These tests are about TLS, not keep-alive. A kept-alive connection is still being torn
  /// down by the session's invalidation when the harness stops the listener, which is the
  /// one shape that waits out `HTTPListener.tlsShutdownTimeout`; the test below measures
  /// that wait, and nothing else needs to pay it.
  private static func closing(_ url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue("close", forHTTPHeaderField: "Connection")
    return request
  }

  /// A stop does not wait out NIOSSL's five-second `close_notify` timeout.
  ///
  /// The client completes the handshake, is answered, and then stops reading, so it never
  /// sees the server's `close_notify` and never replies: the state of a client that has gone
  /// or is tearing its own connection down. With NIOSSL's default that held `stop()` for five
  /// seconds; the bound here sits between `tlsShutdownTimeout` and the default, so either
  /// regression fails it. An ordinary `URLSession` client cannot stand in: whether it answers
  /// depends on whether its own teardown races the stop, and it does not lose every time.
  @Test("Stopping a TLS listener does not wait out a client that has gone")
  func stopDoesNotWaitForAGoneClient() async throws {
    var client: (any Channel)?
    var bodyEnded = ContinuousClock.now
    try await withServer(tls: try material()) { port, _ in
      client = try await SilentTLSClient.connect(
        port: port, path: "/api/v1/ping?password=\(Self.password)")
      bodyEnded = .now
    }
    let stop = ContinuousClock.now - bodyEnded
    try await client?.close()
    #expect(stop < .seconds(3), "stopping took \(stop); the close_notify wait is back")
  }

  @Test("The configured close_notify wait is shorter than NIOSSL's default")
  func shutdownTimeoutIsConfigured() throws {
    let configuration = try HTTPListener.tlsConfiguration(from: try material())
    #expect(configuration.shutdownTimeout == HTTPListener.tlsShutdownTimeout)
    #expect(configuration.shutdownTimeout < .seconds(5))
  }

  @Test("A plaintext request to a TLS listener does not succeed")
  func plaintextIsRefusedWhenTLSIsOn() async throws {
    // The other half of "no silent downgrade": if TLS is on, `http://` must not work.
    try await withServer(tls: try material()) { port, _ in
      let url = URL(string: "http://127.0.0.1:\(port)/api/v1/ping")!
      var request = URLRequest(url: url)
      request.timeoutInterval = 5

      await #expect(throws: (any Error).self) {
        _ = try await URLSession(configuration: .ephemeral).data(for: request)
      }
    }
  }

  @Test("Without a certificate the server is plain HTTP, as before")
  func plaintextRemainsTheDefault() async throws {
    // Most installs sit behind a tunnel that terminates TLS for them, and adding a
    // second layer inside it buys nothing. Off stays off.
    try await withServer(tls: nil) { port, _ in
      let url = URL(
        string: "http://127.0.0.1:\(port)/api/v1/ping?password=\(Self.password)"
      )!
      let (_, response) = try await URLSession.shared.data(from: url)
      #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
  }
}

@Suite("TLS hostname selection")
struct TLSHostnameTests {

  @Test("The published address is included, without scheme or port")
  func publishedAddressIsIncluded() {
    // A certificate valid only for "localhost" is rejected by every client that is not on
    // this machine, which is all of them.
    let names = TLSProvisioning.hostnames(publishedAddress: "https://mac.example.com:1234")
    #expect(names.contains("mac.example.com"))
    #expect(!names.contains { $0.contains(":") })
    #expect(!names.contains { $0.contains("/") })
  }

  @Test("Localhost is always present")
  func localhostAlwaysPresent() {
    #expect(TLSProvisioning.hostnames().contains("localhost"))
  }

  @Test("An empty published address contributes nothing")
  func emptyAddressIsIgnored() {
    let names = TLSProvisioning.hostnames(publishedAddress: "")
    #expect(!names.contains(""))
  }

  /// The bug that made HTTPS fail to start on a default macOS install.
  ///
  /// A SAN dNSName is an ASN.1 IA5String (ASCII only) so one non-ASCII byte makes the
  /// whole certificate unencodable and generation throws. The macOS default computer name
  /// is "<Name>’s MacBook Pro" with a U+2019 apostrophe, so a freshly installed server with
  /// HTTPS switched on could not generate a certificate at all and silently served
  /// plaintext. Nothing in the unit tests could see it; it took booting the server.
  @Test("Every produced hostname is a valid DNS name")
  func hostnamesAreAlwaysValidDNS() {
    let candidates = [
      "Zach’s MacBook Pro",  // the real default, with a smart apostrophe
      "Zach's MacBook Pro",  // and with a straight one
      "café.example.com",
      "🎉.example.com",
      "MAC.EXAMPLE.COM",
      "-leading-hyphen.example.com",
      "trailing-hyphen-.example.com",
      String(repeating: "a", count: 300),
    ]

    for candidate in candidates {
      for name in TLSProvisioning.hostnames(publishedAddress: candidate) {
        #expect(
          name.allSatisfy { $0.isASCII },
          "\(name.debugDescription) from \(candidate.debugDescription) is not ASCII"
        )
        #expect(!name.hasPrefix("-") && !name.hasSuffix("-"))
        #expect(!name.isEmpty)
        #expect(name.count <= 253)
      }
    }
  }

  @Test("A certificate generates for every one of those names")
  func certificateGeneratesForAwkwardNames() throws {
    // The end of the same story: the names have to be usable, not merely well-formed.
    for candidate in ["Zach’s MacBook Pro", "café.example.com", "🎉"] {
      let names = TLSProvisioning.hostnames(publishedAddress: candidate)
      #expect(throws: Never.self) {
        _ = try CertificateAuthority.selfSigned(hostnames: names)
      }
    }
  }

  @Test("The Bonjour name matches what macOS derives")
  func bonjourNameMatchesMacOS() {
    // macOS REMOVES the apostrophe rather than hyphenating it: "Zach's MacBook Pro"
    // resolves as `zachs-macbook-pro.local`, not `zach-s-macbook-pro.local`. Getting it
    // wrong produces a certificate for a name nothing resolves.
    #expect(TLSProvisioning.bonjourName("Zach’s MacBook Pro") == "zachs-macbook-pro")
    #expect(TLSProvisioning.bonjourName("Zach's MacBook Pro") == "zachs-macbook-pro")
    #expect(TLSProvisioning.bonjourName("Mac mini") == "mac-mini")
  }

  @Test("A name with nothing usable in it is dropped, not substituted")
  func unusableNamesAreDropped() {
    // A name nobody can connect by is worth nothing in a certificate, and an invalid one
    // costs the entire certificate.
    #expect(TLSProvisioning.dnsName("🎉") == nil)
    #expect(TLSProvisioning.dnsName("") == nil)
    #expect(TLSProvisioning.dnsName("---") == nil)
  }
}

/// A TLS client that sends one request, reads the answer, and then reads nothing more.
///
/// Auto-read goes off once the response arrives, so a `close_notify` the server sends later is
/// never read and never answered, which a `URLSession` cannot be made to do on purpose.
private enum SilentTLSClient {

  static func connect(port: Int, path: String) async throws -> any Channel {
    var tls = TLSConfiguration.makeClientConfiguration()
    // The listener presents a self-signed certificate; this test is about the shutdown.
    tls.certificateVerification = .none
    // This client's own close cannot read a reply either, so it would wait out the same
    // five seconds when the test closes it.
    tls.shutdownTimeout = .zero
    let context = try NIOSSLContext(configuration: tls)
    let group = MultiThreadedEventLoopGroup.singleton
    let answered = group.next().makePromise(of: Void.self)

    let channel = try await ClientBootstrap(group: group)
      .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            NIOSSLClientHandler(context: context, serverHostname: nil))
          try channel.pipeline.syncOperations.addHandler(StopReadingOnAnswer(answered: answered))
        }
      }
      .connect(host: "127.0.0.1", port: port).get()

    let request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n"
    try await channel.writeAndFlush(channel.allocator.buffer(string: request)).get()
    try await answered.futureResult.get()
    return channel
  }

  private final class StopReadingOnAnswer: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    let answered: EventLoopPromise<Void>

    init(answered: EventLoopPromise<Void>) { self.answered = answered }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in
        self.answered.succeed()
      }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
      answered.fail(error)
    }
  }
}
