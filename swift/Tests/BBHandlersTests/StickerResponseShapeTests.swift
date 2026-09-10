//  StickerResponseShapeTests
//  What the handler actually emits, held against what the document says it emits.
//
//  This is the check the OpenAPI tables did not have. Every schema in `ResponseBodies` is
//  hand-written: it exists precisely for routes with no recorded fixture, and every test
//  over it until now compared the declaration against ITSELF: that the fields have
//  descriptions, that the example only uses declared keys, that a mirror resolves. Nothing
//  executed a handler and looked at the keys that came out.
//
//  So a declaration could be wrong in a way no test could see, and one was. `sticker.save`
//  answers two ways (the sticker as the store holds it, or, on a Mac without Full Disk
//  Access, an acknowledgement with four fields) and the table described only the first. The
//  emitted document therefore declared `identifier`, `kind` and `effect` REQUIRED on a
//  response that carries none of them, and omitted `saved` entirely. A client generating a
//  decoder from it got one that fails on a response the server legitimately sends.
//
//  The two serializers are called here for their key sets alone. That is deliberately all
//  this asserts: the VALUES are the handler's business and are covered elsewhere, while the
//  key set is the part the document makes a promise about.

import BBIMessage
import BBOpenAPI
import BBPrivateAPIContract
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers

@Suite("The sticker responses match what the document declares")
struct StickerResponseShapeTests {

  /// The declared shapes for `sticker.save`, by the field set each promises.
  private var declaredVariants: [Set<String>] {
    guard let body = ResponseBodies.byHandler[.stickerSave] else { return [] }
    return body.variants.map { Set($0.properties.map(\.name)) }
  }

  private func keys(of value: JSONValue) throws -> Set<String> {
    guard case .object(let members) = value else {
      Issue.record("expected a JSON object")
      return []
    }
    return Set(members.keys)
  }

  private var sticker: StickerRow {
    StickerRow(
      identifier: "EADAA97E-1126-409E-9000-74BD19B39E32",
      shelf: .recent,
      externalURI: "sticker:///user/identifier/8A7657D3-E58A-440B-8FCA-7F4389F49DEA",
      name: "BB Test",
      accessibilityName: "teal circle",
      searchText: nil,
      byteCount: 528,
      effect: -1,
      createdAt: Date(timeIntervalSince1970: 1_788_396_119),
      lastUsedAt: Date(timeIntervalSince1970: 1_788_396_119),
      libraryIndex: 14336,
      attributionName: "Stickers",
      attributionBundleID: nil,
      representations: []
    )
  }

  @Test("sticker.save declares both of the shapes it can answer with")
  func bothShapesAreDeclared() {
    // Two, not one. The whole finding: a route that degrades had no way to say so, so the
    // degraded shape was undocumented rather than deliberately omitted.
    #expect(declaredVariants.count == 2)
  }

  @Test("The readable-store response emits exactly the fields declared for it")
  func fullShapeMatches() throws {
    let emitted = try keys(of: StickerHandlers.serialize(sticker))

    guard let declared = declaredVariants.first(where: { $0.contains("identifier") }) else {
      Issue.record("no declared shape carries an identifier")
      return
    }
    #expect(
      emitted == declared,
      """
      the readable-store response and its declaration disagree.
      emitted but not declared: \(emitted.subtracting(declared).sorted())
      declared but not emitted: \(declared.subtracting(emitted).sorted())
      """)
  }

  @Test("The unreadable-store response emits exactly the fields declared for it")
  func degradedShapeMatches() throws {
    let saved = SavedSticker(
      identifier: "8A7657D3-E58A-440B-8FCA-7F4389F49DEA",
      externalURI: "sticker:///user/identifier/8A7657D3-E58A-440B-8FCA-7F4389F49DEA",
      byteCount: 528
    )
    let emitted = try keys(of: StickerHandlers.serializeUnreadable(saved))

    guard let declared = declaredVariants.first(where: { !$0.contains("identifier") }) else {
      Issue.record("no declared shape omits the identifier")
      return
    }
    #expect(
      emitted == declared,
      """
      the unreadable-store response and its declaration disagree.
      emitted but not declared: \(emitted.subtracting(declared).sorted())
      declared but not emitted: \(declared.subtracting(emitted).sorted())
      """)
  }

  @Test("The degraded response carries no identifier, in either spelling")
  func degradedCarriesNoIdentifier() throws {
    // The reason the shapes differ at all. The only identifier available at that point is
    // the donation's, which every read route answers 404 for, so sending it would hand a
    // client something worse than nothing.
    let saved = SavedSticker(
      identifier: "8A7657D3-E58A-440B-8FCA-7F4389F49DEA",
      externalURI: "sticker:///user/identifier/8A7657D3-E58A-440B-8FCA-7F4389F49DEA",
      byteCount: 528
    )
    let emitted = try keys(of: StickerHandlers.serializeUnreadable(saved))

    #expect(!emitted.contains("identifier"))
    #expect(!emitted.contains("id"))
    // And it does say the save worked, which is the one thing the remaining fields cannot.
    #expect(emitted.contains("saved"))
  }

  @Test("The two shapes agree about every field they share")
  func sharedFieldsAgree() throws {
    // `external_uri`, `byte_count` and `shelf` are on both. A client that reads those
    // before branching must not have to know which shape it got, so they have to be
    // spelled the same on each, and a rename on one side only is exactly the kind of
    // drift a hand-written table invites.
    let full = try keys(of: StickerHandlers.serialize(sticker))
    let degraded = try keys(
      of: StickerHandlers.serializeUnreadable(
        SavedSticker(identifier: "x", externalURI: "sticker:///user/identifier/x", byteCount: 1)
      ))

    #expect(degraded.subtracting(["saved"]).isSubset(of: full))
  }
}
