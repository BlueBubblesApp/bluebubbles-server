//  FaceTimeResponseShapeTests
//  The three hand-written FaceTime schemas, held against what the handlers emit.
//
//  These were the last declarations in `ResponseBodies` with nothing executing the code they
//  describe: the same state `sticker.save` was in when it turned out to be documenting one
//  of two shapes it answers with. See `StickerResponseShapeTests` for that one.
//
//  What makes these different, and worth more than a key-set comparison: every one of these
//  serializers emits CONDITIONAL keys. A link carries `group_uuid`, `name` and `expiration`
//  only when it has them; a call carries `address` and `group_uuid` only when it has them. So
//  the declaration's `required:` flags are a real claim about runtime behaviour, and it is
//  exactly the claim that was wrong on `sticker.save`: three fields marked required on a
//  response that carries none of them.
//
//  Each shape is therefore driven twice: once with every optional value present, and once
//  with all of them absent. The first pins what a client may ever receive; the second pins
//  what it can rely on always being there.

import BBHTTPAPI
import BBOpenAPI
import BBPrivateAPIContract
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers

@Suite("The FaceTime responses match what the document declares")
struct FaceTimeResponseShapeTests {

  // MARK: - Reading the declaration

  private func declared(_ handler: HandlerID) -> [ResponseBodies.Property] {
    ResponseBodies.byHandler[handler]?.variants.first?.properties ?? []
  }

  /// The declared field names at the top level of a response.
  private func declaredNames(_ handler: HandlerID) -> Set<String> {
    Set(declared(handler).map(\.name))
  }

  /// The declared field names a client is promised on every response.
  private func declaredRequired(_ handler: HandlerID) -> Set<String> {
    Set(declared(handler).filter(\.isRequired).map(\.name))
  }

  /// The declared field names nested inside one top-level property.
  private func declaredNested(
    _ handler: HandlerID, _ property: String, requiredOnly: Bool = false
  ) -> Set<String> {
    guard let outer = declared(handler).first(where: { $0.name == property }),
      case .object(let properties) = outer.schema
    else {
      Issue.record("\(handler.rawValue).\(property) is not declared as an object")
      return []
    }
    return Set(properties.filter { !requiredOnly || $0.isRequired }.map(\.name))
  }

  private func keys(_ value: JSONValue?) -> Set<String> {
    guard case .object(let members)? = value else {
      Issue.record("expected a JSON object")
      return []
    }
    return Set(members.keys)
  }

  // MARK: - Fixtures

  /// Everything optional present.
  private var fullLink: FaceTimeLink {
    FaceTimeLink(
      url: "https://facetime.apple.com/join#v=1&p=example",
      groupUUID: "9E3C0B77-1A44-4D2E-8F51-7C2B9D6E0A13",
      name: "Standup",
      expiresAt: Date(timeIntervalSince1970: 1_788_396_119)
    )
  }

  /// Nothing optional present: a link FaceTime minted with no conversation formed yet.
  private var bareLink: FaceTimeLink {
    FaceTimeLink(url: "https://facetime.apple.com/join#v=1&p=example")
  }

  private var fullCall: FaceTimeCall {
    FaceTimeCall(
      callUUID: "2B62987D-4F1C-4A2E-9C3D-6E5B1A7F0C22",
      status: .outgoing,
      handle: FaceTimeHandle(value: "+15551234567"),
      groupUUID: "9E3C0B77-1A44-4D2E-8F51-7C2B9D6E0A13",
      isVideo: true
    )
  }

  /// A group call with no single peer and no conversation yet.
  private var bareCall: FaceTimeCall {
    FaceTimeCall(callUUID: "2B62987D-4F1C-4A2E-9C3D-6E5B1A7F0C22", status: .outgoing)
  }

  // MARK: - facetime/call

  @Test("A placed call emits exactly the two declared halves")
  func placedCallTopLevel() {
    let emitted = keys(FaceTimeHandlers.placedCallPayload(link: fullLink, call: fullCall))
    #expect(emitted == declaredNames(.facetimeCall))
    // Both halves are declared required, and a call response is useless without either.
    #expect(emitted == declaredRequired(.facetimeCall))
  }

  @Test("A fully-populated call fills every field the document declares")
  func placedCallFullyPopulated() {
    guard
      case .object(let members) = FaceTimeHandlers.placedCallPayload(
        link: fullLink, call: fullCall)
    else {
      Issue.record("not an object")
      return
    }
    #expect(keys(members["link"]) == declaredNested(.facetimeCall, "link"))
    #expect(keys(members["call"]) == declaredNested(.facetimeCall, "call"))
  }

  @Test("A call with nothing optional still carries every field declared required")
  func placedCallBare() {
    // The claim the `required:` flags make, and the one that was false on `sticker.save`.
    guard
      case .object(let members) = FaceTimeHandlers.placedCallPayload(
        link: bareLink, call: bareCall)
    else {
      Issue.record("not an object")
      return
    }
    #expect(keys(members["link"]) == declaredNested(.facetimeCall, "link", requiredOnly: true))
    #expect(keys(members["call"]) == declaredNested(.facetimeCall, "call", requiredOnly: true))
  }

  // MARK: - facetime/:call_uuid/handoff

  @Test("A hand-off emits exactly the declared fields, and both spellings of the link")
  func handoffFullyPopulated() {
    let emitted = keys(FaceTimeHandlers.inheritedLinkPayload(fullLink))
    #expect(emitted == declaredNames(.facetimeHandoff))
    // `link` and `url` are the same value under two names: the second is what the rest of
    // the FaceTime surface calls it, the first is what this route has always answered with.
    // Both are declared required, so both have to survive a bare link.
    #expect(emitted.contains("link"))
    #expect(emitted.contains("url"))
  }

  @Test("A hand-off with a bare link still carries every field declared required")
  func handoffBare() {
    let emitted = keys(FaceTimeHandlers.inheritedLinkPayload(bareLink))
    #expect(emitted == declaredRequired(.facetimeHandoff))
  }

  // MARK: - facetime/:group_uuid/admit

  @Test("An admission emits exactly the declared fields")
  func admitShape() {
    let emitted = keys(FaceTimeHandlers.admittedPayload(address: "+15551234567"))
    #expect(emitted == declaredNames(.facetimeAdmit))
    // Nothing here is conditional, so every field is required and the two sets agree.
    #expect(emitted == declaredRequired(.facetimeAdmit))
  }

  @Test("An admission always reports success rather than a boolean to interpret")
  func admitIsAlwaysTrue() {
    guard case .object(let members) = FaceTimeHandlers.admittedPayload(address: "a@b.invalid"),
      case .bool(let admitted)? = members["admitted"]
    else {
      Issue.record("admitted is not a boolean")
      return
    }
    // A refusal is an error response. If this ever answered `false`, a client branching on
    // it would show "not admitted" for a 200 that meant the opposite.
    #expect(admitted)
  }
}
