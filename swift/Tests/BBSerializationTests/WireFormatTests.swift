//  WireFormatTests
//  The envelope and the JSON value model.
//
//  These assert the two properties WireTypes.swift exists to provide and that synthesised
//  Codable cannot: a key can be ABSENT rather than null, and a Bool stays a Bool rather than
//  decaying into 1/0. Both are silent client breaks — a strict parser rejects a null where it
//  expected a missing key, and a client reading `isFromMe` gets `1` instead of `true`.

import BBSerialization
import Foundation
import Testing

@Suite("JSON value model")
struct JSONValueTests {

  /// NSNumber erases Bool, so a naive round trip turns `true` into `1`. The wire format
  /// says `true`, and a client comparing against a boolean silently stops matching.
  @Test("A Bool survives a parse round trip as a Bool, not as 1")
  func boolIsNotCoercedToInteger() throws {
    let original = JSONValue.object(["isFromMe": .bool(true), "count": .int(1)])
    let reparsed = try JSONValue.parse(original.serialize())

    #expect(reparsed["isFromMe"] == .bool(true))
    #expect(reparsed["isFromMe"] != .int64(1))
    // And the converse: a genuine 1 must not become `true`.
    #expect(reparsed["count"] == .int64(1))
  }

  /// Message ROWIDs and epoch-millisecond dates both exceed Int32, and a lossy round trip
  /// through Double would silently corrupt the large ones.
  @Test("Int64 values round-trip without loss")
  func int64SurvivesRoundTrip() throws {
    let large: Int64 = 1_735_689_600_000
    let reparsed = try JSONValue.parse(JSONValue.object(["dateCreated": .int64(large)]).serialize())
    #expect(reparsed["dateCreated"] == .int64(large))
  }

  /// A Socket.IO event payload is frequently a bare value: `2["hello-world",null]`.
  @Test("Fragments parse, because socket payloads are frequently bare values")
  func fragmentsParse() throws {
    #expect(try JSONValue.parse(Data("null".utf8)) == .null)
    #expect(try JSONValue.parse(Data("\"text\"".utf8)) == .string("text"))
  }

  @Test("Nested structures survive a round trip")
  func nestedRoundTrip() throws {
    let original = JSONValue.object([
      "chats": .array([.object(["guid": .string("iMessage;-;+1"), "style": .int(45)])]),
      "handle": .null,
    ])
    let reparsed = try JSONValue.parse(original.serialize())
    #expect(reparsed["handle"] == .null)
    #expect(reparsed["chats"]?[0]?["guid"] == .string("iMessage;-;+1"))
  }
}

@Suite("Key presence")
struct JSONObjectBuilderTests {

  /// The distinction the whole file exists for. `set` with nil OMITS; `setOrNull` emits
  /// null. Conflating them is what synthesised Codable does and why it is not used here.
  @Test("set omits a nil key; setOrNull emits null")
  func absentIsNotNull() {
    var builder = JSONObjectBuilder()
    builder.set("omitted", nil)
    builder.setOrNull("nulled", nil)

    let result = builder.build()
    #expect(!result.objectKeys.contains("omitted"))
    #expect(result.objectKeys.contains("nulled"))
    #expect(result["nulled"] == .null)
  }

  /// How a macOS-gated field stays absent on an older release rather than becoming null.
  @Test("setIf gates on the schema, and a false gate omits entirely")
  func schemaGateOmits() {
    var present = JSONObjectBuilder()
    present.setIf(true, "partCount", .int(2))
    #expect(present["partCount"] == .int(2))

    var absent = JSONObjectBuilder()
    absent.setIf(false, "partCount", .int(2))
    #expect(!absent.build().objectKeys.contains("partCount"))

    // setIfOrNull differs only in what a PRESENT column with no value produces.
    var nulled = JSONObjectBuilder()
    nulled.setIfOrNull(true, "dateEdited", nil)
    #expect(nulled["dateEdited"] == .null)

    var gatedOut = JSONObjectBuilder()
    gatedOut.setIfOrNull(false, "dateEdited", nil)
    #expect(!gatedOut.build().objectKeys.contains("dateEdited"))
  }

  /// `setIf` must not evaluate its value when the gate is closed — the value expression
  /// reads a column that does not exist on that schema.
  @Test("A closed gate does not evaluate its value")
  func closedGateDoesNotEvaluate() {
    final class Counter: @unchecked Sendable { var count = 0 }
    let counter = Counter()

    var builder = JSONObjectBuilder()
    builder.setIf(
      false, "key",
      {
        counter.count += 1
        return .int(1)
      }())
    #expect(counter.count == 0)
  }
}

extension JSONObjectBuilder {
  /// Read-through for assertions, so tests do not have to build twice.
  fileprivate subscript(key: String) -> JSONValue? { build()[key] }
}

extension JSONValue {
  fileprivate subscript(index: Int) -> JSONValue? {
    guard case .array(let values) = self, values.indices.contains(index) else { return nil }
    return values[index]
  }
}

@Suite("Response envelope")
struct ResponseEnvelopeTests {

  /// `data` and `metadata` are omitted when absent, never emitted as null. A strict client
  /// parser treats the two differently.
  @Test("Absent data and metadata are omitted, not nulled")
  func absentFieldsAreOmitted() throws {
    let envelope = ResponseEnvelope(status: 200, message: "Success")
    let decoded = try JSONValue.parse(envelope.encoded())

    #expect(decoded.objectKeys == ["status", "message"])
    #expect(decoded["status"] == .int64(200))
    #expect(decoded["message"] == .string("Success"))
  }

  @Test("Present data is included")
  func presentDataIsIncluded() throws {
    let envelope = ResponseEnvelope.success(
      .object(["guid": .string("A1")]),
      metadata: .object(["total": .int(1)])
    )
    let decoded = try JSONValue.parse(envelope.encoded())

    #expect(decoded["data"]?["guid"] == .string("A1"))
    #expect(decoded["metadata"]?["total"] == .int64(1))
  }

  /// The AES path is retired but clients still read the field, so it must survive when set
  /// — and stay absent when not, rather than appearing as false.
  @Test("encrypted appears only when set")
  func encryptedIsOptional() throws {
    let without = try JSONValue.parse(ResponseEnvelope(status: 200, message: "Success").encoded())
    #expect(!without.objectKeys.contains("encrypted"))

    let with = try JSONValue.parse(
      ResponseEnvelope(status: 200, message: "Success", encrypted: false).encoded()
    )
    #expect(with["encrypted"] == .bool(false))
  }

  @Test("An error body carries its type and message")
  func errorBodyShape() throws {
    let envelope = ResponseEnvelope(
      status: 400,
      message: ResponseMessage.badRequest.rawValue,
      error: ErrorBody(type: .validationError, message: "chatGuid is required")
    )
    let decoded = try JSONValue.parse(envelope.encoded())

    #expect(decoded["error"]?["type"] == .string("Validation Error"))
    #expect(decoded["error"]?["message"] == .string("chatGuid is required"))
  }

  /// POST /facetime/leave/:call_uuid answers 201 "No Data" rather than 200 "Success".
  @Test("noData is 201, not 200")
  func noDataStatus() throws {
    let decoded = try JSONValue.parse(ResponseEnvelope.noData().encoded())
    #expect(decoded["status"] == .int64(201))
    #expect(decoded["message"] == .string("No Data"))
  }

  /// The original enum spells this DATABSE_ERROR. The wire value is what clients match on,
  /// so it is the spelling that has to be right.
  @Test("Wire strings for the error types are frozen")
  func errorTypeWireValues() {
    #expect(ErrorType.databaseError.rawValue == "Database Error")
    #expect(ErrorType.iMessageError.rawValue == "iMessage Error")
    #expect(ResponseMessage.unknownIMessageError.rawValue == "Unknown iMessage Error")
  }
}
