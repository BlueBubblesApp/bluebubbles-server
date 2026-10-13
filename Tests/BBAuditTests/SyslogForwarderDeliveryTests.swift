//  SyslogForwarderDeliveryTests
//  What reaches a real receiver, rather than what the forwarder believes it sent.
//
//  Two defects, both found by measuring against a listener:
//
//    - **One oversized record stopped forwarding for good.** macOS refuses a datagram past
//      `net.inet.udp.maxdgram` (9,216 bytes by default), the forwarder retried the head of
//      its queue for ever, and every record behind it waited until a restart.
//    - **Stopping threw the queue away.** `audit.recording_stopped` is queued last and was
//      never sent, so a receiver could not tell a clean stop from a cut feed.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBCore
import BBTestSupport
import Foundation
import Testing

@testable import BBAudit

@Suite("Syslog forwarder delivery", .serialized)
struct SyslogForwarderDeliveryTests {

  private func record(_ summary: String, blob: Int = 0) -> AuditEvent {
    AuditEvent(
      kind: .settingsChanged, actor: .operator, summary: summary,
      metadata: blob > 0 ? ["value": .string(String(repeating: "x", count: blob))] : [:])
  }

  /// The JSON body of a syslog message: everything after the structured-data field.
  private func body(of message: String) throws -> [String: JSONValue] {
    let start = try #require(message.firstIndex(of: "{"))
    let value = try AuditJSON.decode(JSONValue.self, from: Data(message[start...].utf8))
    guard case .object(let fields) = value else { throw POSIXError(.EINVAL) }
    return fields
  }

  @Test("An oversized record is shrunk to a datagram, and the records behind it still arrive")
  func oversizedDatagramDoesNotWedge() async throws {
    let receiver = try LoopbackSyslogReceiver(.udp)
    defer { receiver.stop() }
    let forwarder = SyslogForwarder(
      destination: SyslogDestination(host: "127.0.0.1", port: receiver.port, transport: .udp),
      hostname: "mac")
    let big = record("too big", blob: 20_000)
    await forwarder.export([big, record("after")])

    let arrived = try await receiver.waitFor(2)
    await forwarder.stop()
    try #require(arrived.count == 2, "received \(arrived.count) of 2")

    #expect(arrived[0].utf8.count <= SyslogMessage.datagramLimit)
    let shrunk = try body(of: arrived[0])
    // The envelope survives, so the receiver's copy still joins the local one by uuid.
    #expect(shrunk["uuid"] == .string(big.uuid.uuidString.lowercased()))
    #expect(shrunk["summary"] == .string("too big"))
    guard case .object(let metadata)? = shrunk["metadata"] else {
      Issue.record("metadata is not an object")
      return
    }
    #expect(metadata["truncated"] == .bool(true))
    if case .int(let original)? = metadata["original_bytes"] {
      #expect(original > SyslogMessage.datagramLimit)
    } else {
      Issue.record("the truncation marker does not say how large the record was")
    }
    #expect(try body(of: arrived[1])["summary"] == .string("after"))
  }

  @Test("A record that fits is sent whole")
  func recordThatFitsIsUntouched() {
    let small = record("small", blob: 100)
    let message = SyslogMessage.format(
      small, hostname: "mac", processID: 1, facility: .local0, softwareVersion: nil,
      maximumBytes: SyslogMessage.datagramLimit)
    let unlimited = SyslogMessage.format(
      small, hostname: "mac", processID: 1, facility: .local0, softwareVersion: nil)
    #expect(message == unlimited)
  }

  @Test("A summary too long for the budget on its own is cut, and the message still fits")
  func longSummaryIsCut() throws {
    let wordy = record(String(repeating: "é", count: 6_000))
    let message = SyslogMessage.format(
      wordy, hostname: "mac", processID: 1, facility: .local0, softwareVersion: nil,
      maximumBytes: 2_048)
    #expect(message.utf8.count <= 2_048)
    guard case .string(let summary)? = try body(of: message)["summary"] else {
      Issue.record("no summary")
      return
    }
    #expect(summary.hasSuffix("…"))
  }

  @Test("Stopping delivers what is queued while the receiver is answering")
  func stopDrainsTheQueue() async throws {
    let receiver = try LoopbackSyslogReceiver(.tcp)
    defer { receiver.stop() }
    let forwarder = SyslogForwarder(
      destination: SyslogDestination(host: "127.0.0.1", port: receiver.port, transport: .tcp),
      hostname: "mac")
    // Connected first: the drain is for a receiver that is answering.
    await forwarder.export([record("first")])
    #expect(try await receiver.waitFor(1).count == 1)

    await forwarder.export((1...200).map { record("queued \($0)") })
    await forwarder.stop()
    let arrived = try await receiver.waitFor(201, timeout: .seconds(3))
    #expect(arrived.count == 201, "received \(arrived.count) of 201")
    #expect(await forwarder.queuedCount == 0)
  }

  @Test("Stopping does not wait on a receiver that is not answering")
  func stopIsBoundedWhenFailing() async throws {
    // A port nothing listens on: the connection is refused and the forwarder backs off.
    let closed = try LoopbackSyslogReceiver(.tcp)
    let port = closed.port
    closed.stop()
    try await Task.sleep(for: .milliseconds(150))
    let forwarder = SyslogForwarder(
      destination: SyslogDestination(host: "127.0.0.1", port: port, transport: .tcp),
      hostname: "mac")
    await forwarder.export([record("nowhere")])
    try await Task.sleep(for: .milliseconds(200))

    let started = ContinuousClock.now
    await forwarder.stop()
    #expect(ContinuousClock.now - started < .seconds(1))
  }

  /// A receiver that accepts the connection and never answers the TLS handshake. NIOSSL
  /// holds the write until the handshake completes, so the write's future never resolves;
  /// `EventLoopFuture.get()` ignores cancellation, and a `withTimeout` around it waited for
  /// it for ever. The forwarder sat in `.idle` with the sender stuck, and nothing reported it.
  @Test("A write that never completes is given up at its deadline")
  func writeDeadlineIsReal() async throws {
    let receiver = try LoopbackSyslogReceiver(.tcp)
    defer { receiver.stop() }
    let forwarder = SyslogForwarder(
      destination: SyslogDestination(host: "127.0.0.1", port: receiver.port, transport: .tls),
      hostname: "mac", writeTimeout: .milliseconds(300))
    await forwarder.export([record("held")])

    try await waitUntil("the forwarder to report the stalled write", timeout: .seconds(5)) {
      if case .failing = await forwarder.currentState { return true }
      return false
    }
    // The record was not lost to the failure: it waits for the retry.
    #expect(await forwarder.queuedCount == 1)

    let started = ContinuousClock.now
    await forwarder.stop()
    #expect(ContinuousClock.now - started < .seconds(1))
  }

  /// A stop that returns has nothing of the forwarder still running, so a record exported
  /// after it (a flush that raced the stop) neither queues nor opens a fresh connection.
  @Test("Nothing is sent after a stop")
  func nothingIsSentAfterStop() async throws {
    let receiver = try LoopbackSyslogReceiver(.tcp)
    defer { receiver.stop() }
    let forwarder = SyslogForwarder(
      destination: SyslogDestination(host: "127.0.0.1", port: receiver.port, transport: .tcp),
      hostname: "mac")
    await forwarder.export([record("before")])
    #expect(try await receiver.waitFor(1).count == 1)
    await forwarder.stop()

    await forwarder.export([record("after")])
    #expect(await forwarder.queuedCount == 0)
    await forwarder.settle()
    try await Task.sleep(for: .milliseconds(200))
    #expect(receiver.messages.count == 1)
  }

  /// A send in flight when the stop cancels it neither traps on a queue the stop emptied nor
  /// puts its record back into it.
  @Test("A stop during an in-flight send ends it and leaves the queue empty")
  func stopDuringInFlightSend() async throws {
    let receiver = try LoopbackSyslogReceiver(.tcp)
    defer { receiver.stop() }
    let forwarder = SyslogForwarder(
      destination: SyslogDestination(host: "127.0.0.1", port: receiver.port, transport: .tls),
      hostname: "mac", writeTimeout: .seconds(30))
    await forwarder.export([record("in flight"), record("behind it")])
    // Long enough for the connection to open and the first write to stall on the handshake.
    try await Task.sleep(for: .milliseconds(200))

    let started = ContinuousClock.now
    await forwarder.stop()
    #expect(ContinuousClock.now - started < .seconds(1))
    #expect(await forwarder.queuedCount == 0)
    await forwarder.settle()
    #expect(await forwarder.queuedCount == 0)
  }
}
