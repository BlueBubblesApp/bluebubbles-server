//  SocketCodecTests
//  Every vector was produced by socket.io-parser 4.2.7 and engine.io-parser 5.2.3.
//
//  "Correct" here means byte-identical to the reference implementations, not "parses". A
//  malformed socket frame does not fail loudly — the client ignores it and messages simply
//  stop arriving, which is reported as "the server stopped working" weeks later.

import BBSerialization
import Foundation
import Testing

@testable import BBSocketIO

// MARK: - Fixture model

struct SocketIOVector: Codable {
  let name: String
  let packet: PacketDescription
  let encoded: [String]

  struct PacketDescription: Codable {
    let type: Int
    let nsp: String?
    let data: JSONFixture?
    let id: Int?
  }
}

struct EngineIOVector: Codable {
  let name: String
  let packet: PacketDescription
  let encoded: String

  struct PacketDescription: Codable {
    let type: String
    let data: JSONFixture?
  }
}

struct EngineIOPayloadVector: Codable {
  let name: String
  let packets: [String]
  let encoded: String
}

struct VectorFile: Codable {
  let socketIO: [SocketIOVector]
  let engineIO: [EngineIOVector]
  let engineIOPayload: EngineIOPayloadVector
}

/// Decodes arbitrary JSON out of the fixture without losing bool-versus-number, which is
/// exactly the distinction a client break would hide behind.
struct JSONFixture: Codable {
  let value: JSONValue

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      value = .null
    } else if let bool = try? container.decode(Bool.self) {
      value = .bool(bool)
    } else if let int = try? container.decode(Int64.self) {
      value = .int64(int)
    } else if let double = try? container.decode(Double.self) {
      value = .double(double)
    } else if let string = try? container.decode(String.self) {
      value = .string(string)
    } else if let array = try? container.decode([JSONFixture].self) {
      value = .array(array.map(\.value))
    } else if let object = try? container.decode([String: JSONFixture].self) {
      value = .object(object.mapValues(\.value))
    } else {
      value = .null
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(String(data: value.serialize(), encoding: .utf8) ?? "null")
  }
}

func loadVectors() throws -> VectorFile {
  let url = try #require(
    Bundle.module.url(
      forResource: "socketio-vectors", withExtension: "json",
      subdirectory: "ProtocolFixtures")
  )
  return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
}

// MARK: - Socket.IO

@Suite("Socket.IO packet encoding")
struct SocketIOEncodingTests {

  @Test("Every reference vector round-trips to the same bytes")
  func matchesReferenceVectors() throws {
    let vectors = try loadVectors()

    for vector in vectors.socketIO {
      let type = try #require(SocketIOPacketType(rawValue: vector.packet.type))
      let packet = SocketIOPacket(
        type: type,
        namespace: vector.packet.nsp ?? "/",
        data: vector.packet.data?.value,
        ackID: vector.packet.id
      )

      let encoded = try packet.encode()
      expectFrameEquivalent(encoded, vector.encoded[0], name: vector.name)
    }
  }

  @Test("The default namespace is never written")
  func defaultNamespaceIsOmitted() throws {
    // `0/,` instead of `0` breaks every client. Trivial to reintroduce while "cleaning
    // up" the encoder, so it gets its own test rather than living only in the vectors.
    let packet = SocketIOPacket(type: .connect, namespace: "/")
    #expect(try packet.encode() == "0")
  }

  @Test("The ack id sits between the type and the payload")
  func ackIDPlacement() throws {
    let packet = SocketIOPacket.event(name: "get-server-metadata", payload: .object([:]), ackID: 17)
    #expect(try packet.encode() == "217[\"get-server-metadata\",{}]")
  }

  @Test("CONNECT with no data is bare")
  func bareConnect() throws {
    // `0{}` is a different packet on the wire from `0`.
    #expect(try SocketIOPacket.connect(sid: nil).encode() == "0")
    #expect(try SocketIOPacket.connect(sid: "abc123").encode() == "0{\"sid\":\"abc123\"}")
  }

  @Test("A null event payload encodes as null, not as an omitted argument")
  func nullPayload() throws {
    let packet = SocketIOPacket.event(name: "hello-world", payload: nil)
    #expect(try packet.encode() == "2[\"hello-world\",null]")
  }
}

@Suite("Socket.IO packet decoding")
struct SocketIODecodingTests {

  @Test("Every reference vector decodes back to its packet")
  func decodesReferenceVectors() throws {
    let vectors = try loadVectors()

    for vector in vectors.socketIO {
      let decoded = try #require(
        SocketIOPacket.decode(vector.encoded[0]), "\(vector.name) failed to decode"
      )
      #expect(decoded.type.rawValue == vector.packet.type, "\(vector.name): wrong type")
      #expect(decoded.namespace == (vector.packet.nsp ?? "/"), "\(vector.name): wrong nsp")
      #expect(decoded.ackID == vector.packet.id, "\(vector.name): wrong ack id")
    }
  }

  @Test("Event contents split into name and arguments")
  func eventContents() throws {
    let packet = try #require(SocketIOPacket.decode("2[\"new-message\",{\"guid\":\"A1\"}]"))
    let contents = try #require(packet.eventContents)
    #expect(contents.name == "new-message")
    #expect(contents.arguments.count == 1)
  }

  @Test("A string payload stays a string")
  func stringPayload() throws {
    // incoming-facetime sends a STRINGIFIED object as the payload, not an object. A
    // decoder that eagerly re-parses it changes the shape the handler sees.
    let packet = try #require(
      SocketIOPacket.decode("2[\"incoming-facetime\",\"{\\\"caller\\\":\\\"Jane\\\"}\"]")
    )
    let contents = try #require(packet.eventContents)
    guard case .string = contents.arguments.first else {
      Issue.record("Expected the payload to stay a string")
      return
    }
  }
}

// MARK: - Engine.IO

@Suite("Engine.IO framing")
struct EngineIOTests {

  @Test("Every reference vector encodes identically")
  func matchesReferenceVectors() throws {
    let vectors = try loadVectors()

    for vector in vectors.engineIO {
      // The open handshake carries a structured body; the rest are type + literal.
      guard vector.name != "open-handshake" else { continue }

      let decoded = try #require(
        EngineIOPacket.decode(vector.encoded), "\(vector.name) failed to decode"
      )
      #expect(
        decoded.encode() == vector.encoded,
        "\(vector.name): re-encoding changed the frame"
      )
    }
  }

  @Test("The handshake carries the current server's timeouts")
  func handshakeValues() throws {
    // Not defaults. A client told pingTimeout: 120000 waits two minutes before
    // declaring the connection dead, and shortening these changes reconnect behavior in
    // the field.
    let handshake = EngineIOHandshake(sid: "abc123def456")
    let encoded = try handshake.encode()
    #expect(encoded.hasPrefix("0{"))
    #expect(encoded.contains("\"pingInterval\":60000"))
    #expect(encoded.contains("\"pingTimeout\":120000"))
    #expect(encoded.contains("\"upgrades\":[\"websocket\"]"))
  }

  @Test("Probe packets carry their literal payload")
  func probePackets() {
    // The transport upgrade never completes without these, and the failure is silent:
    // the client stays on polling and every event is delayed by a poll cycle.
    #expect(EngineIOPacket.pingProbe.encode() == "2probe")
    #expect(EngineIOPacket.pongProbe.encode() == "3probe")
  }

  @Test("Payloads join on the record separator")
  func payloadSeparator() throws {
    let vectors = try loadVectors()
    let vector = vectors.engineIOPayload
    #expect(EngineIOPayload.encode(vector.packets) == vector.encoded)
    #expect(EngineIOPayload.decode(vector.encoded) == vector.packets)
    // U+001E. Not a comma, not a newline.
    #expect(EngineIOPayload.separator == "\u{1e}")
  }

  @Test("Engine.IO wraps Socket.IO")
  func wireFraming() throws {
    let packet = SocketIOPacket.event(
      name: "new-message", payload: .object(["guid": .string("A1B2C3D4")])
    )
    #expect(try WireFrame.encode(packet) == "42[\"new-message\",{\"guid\":\"A1B2C3D4\"}]")
  }

  @Test("A wire frame decodes back to its Socket.IO packet")
  func wireRoundTrip() throws {
    let decoded = try #require(WireFrame.decode("42[\"new-message\",{\"guid\":\"A1\"}]"))
    #expect(decoded.eventContents?.name == "new-message")
    // A non-MESSAGE Engine.IO packet carries no Socket.IO packet at all.
    #expect(WireFrame.decode("2") == nil)
  }
}

// MARK: - Handshake options

@Suite("Handshake options")
struct HandshakeOptionTests {

  @Test("A client that asks for nothing gets legacy behavior")
  func defaultsAreLegacy() {
    let options = SocketClientOptions.parse([:])
    #expect(options.engineIOVersion == 4)
    #expect(!options.wantsReplay)
    #expect(options.capabilities.supportedCodecs == [.legacyV1])
  }

  @Test("EIO 3 is supported, not deprecated")
  func engineIOVersion3() {
    // allowEIO3 is load-bearing for older Flutter clients.
    #expect(SocketClientOptions.parse(["EIO": "3"]).engineIOVersion == 3)
  }

  @Test("Replay is opt-in")
  func replayIsOptIn() {
    #expect(SocketClientOptions.parse(["replay": "1"]).wantsReplay)
    #expect(!SocketClientOptions.parse(["replay": "0"]).wantsReplay)
    #expect(!SocketClientOptions.parse([:]).wantsReplay)
  }

  @Test("Declared codecs never remove legacy support")
  func codecsAlwaysIncludeLegacy() {
    let options = SocketClientOptions.parse(["codecs": "sealed-v2,reference-v2"])
    #expect(options.capabilities.supportedCodecs.contains(.legacyV1))
    #expect(options.capabilities.supportedCodecs.contains(.sealedV2))
  }
}

// MARK: - Frame comparison

/// Compares two Socket.IO frames: **framing byte-for-byte, payload structurally**.
///
/// Whole-frame byte equality is not an achievable property, and asserting it made this test
/// flaky rather than strict. `JSONValue.object` is backed by a Swift `Dictionary`, whose key
/// order is arbitrary and varies between processes; the reference vectors come from
/// socket.io-parser, which emits JavaScript insertion order. Nothing can reconcile those two
/// orders, so the assertion failed on whichever vectors happened to hash unfavourably that
/// run — one of the 13 fixtures is not even in sorted order, so no encoder setting fixes it
/// either.
///
/// What the file header actually cares about — a malformed frame the client silently ignores
/// — lives entirely in the framing: the packet type digit, the namespace and its comma, and
/// the ack id. That prefix is compared exactly. The payload after it is compared by value,
/// which is what a client does with it.
func expectFrameEquivalent(
  _ actual: String,
  _ expected: String,
  name: String,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  // The payload begins at the first JSON opener; everything before it is framing.
  func split(_ frame: String) -> (framing: String, payload: String?) {
    guard let start = frame.firstIndex(where: { $0 == "[" || $0 == "{" }) else {
      return (frame, nil)
    }
    return (String(frame[frame.startIndex..<start]), String(frame[start...]))
  }

  let (actualFraming, actualPayload) = split(actual)
  let (expectedFraming, expectedPayload) = split(expected)

  #expect(
    actualFraming == expectedFraming,
    "\(name): framing differs — produced \(actualFraming), reference says \(expectedFraming)",
    sourceLocation: sourceLocation
  )

  switch (actualPayload, expectedPayload) {
  case (nil, nil):
    break
  case (let actualPayload?, let expectedPayload?):
    do {
      let decodedActual = try JSONValue.parse(Data(actualPayload.utf8))
      let decodedExpected = try JSONValue.parse(Data(expectedPayload.utf8))
      #expect(
        decodedActual == decodedExpected,
        "\(name): payload differs — produced \(actualPayload), reference says \(expectedPayload)",
        sourceLocation: sourceLocation
      )
    } catch {
      Issue.record(
        "\(name): a frame payload did not parse as JSON — produced \(actualPayload), reference says \(expectedPayload)",
        sourceLocation: sourceLocation
      )
    }
  default:
    Issue.record(
      "\(name): one frame carries a payload and the other does not — produced \(actual), reference says \(expected)",
      sourceLocation: sourceLocation
    )
  }
}
