//  StickerHandlerTests
//  What the sticker library routes derive from a request, and what they hand back.

import BBIMessage
import BBSystem
import Foundation
import Testing

@testable import BBHandlers

@Suite("Sticker library routes")
struct StickerHandlerTests {

  @Test("A sticker's kind is derived from its external URI")
  func kindsAreDerived() {
    // `kind` exists so a client does not have to parse the URI itself — which matters
    // because the emoji form ends in the emoji CHARACTER and is easy to get wrong.
    #expect(StickerHandlers.kind(of: "sticker:///emoji/identifier/😭") == "emoji")
    #expect(
      StickerHandlers.kind(of: "sticker:///memoji/cow/cow_smiling_face_with_heart-shaped_eyes")
        == "memoji")
    #expect(
      StickerHandlers.kind(of: "sticker:///user/identifier/AC20781C-5A31-40D9-8931-3619AA9783C9")
        == "user")
  }

  @Test("An unrecognised external URI is `unknown`, not a guess")
  func unknownKindsAreAdmitted() {
    // Apple adds sticker sources; reporting a new one as `user` would be worse than
    // admitting we do not know what it is.
    #expect(StickerHandlers.kind(of: "sticker:///genmoji/something/else") == "unknown")
    #expect(StickerHandlers.kind(of: "") == "unknown")
    #expect(StickerHandlers.kind(of: "not a uri at all") == "unknown")
  }

  @Test("Role shorthands expand to the store's own role strings")
  func roleShorthandsExpand() {
    // The real values are long reverse-DNS strings. A client should be able to ask for
    // `still` or `keyboard` without hard-coding them.
    #expect(StickerHandlers.role("still") == StickerRepresentationRow.stillRole)
    #expect(StickerHandlers.role("full") == StickerRepresentationRow.stillRole)
    #expect(StickerHandlers.role("keyboard") == StickerRepresentationRow.keyboardRole)
    #expect(StickerHandlers.role("thumbnail") == StickerRepresentationRow.keyboardRole)
    #expect(StickerHandlers.role("STILL") == StickerRepresentationRow.stillRole)
    // A full role string passes through untouched, so a client reading `role` off a
    // representation can send it straight back.
    #expect(
      StickerHandlers.role(StickerRepresentationRow.stillRole)
        == StickerRepresentationRow.stillRole)
    // Absent means "the preferred one", which is nil rather than a role.
    #expect(StickerHandlers.role(nil) == nil)
    #expect(StickerHandlers.role("") == nil)
  }

  @Test("A representation reports a MIME type, not just a UTI")
  func representationsCarryMIMETypes() {
    // The store records `public.png` and `public.heic`; a client rendering an image needs
    // the MIME type, and deriving one from a filename is impossible here — there is no
    // filename in the store at all.
    #expect(FileTypes.mimeType(forIdentifier: "public.png") == "image/png")
    #expect(FileTypes.mimeType(forIdentifier: "public.heic") == "image/heic")
    // A UTI nothing on this Mac claims is reported as binary rather than guessed at.
    #expect(
      FileTypes.mimeType(forIdentifier: "com.example.not.a.real.type")
        == "application/octet-stream")
  }

  @Test("A serialized sticker carries what a client needs to fetch and show it")
  func serializationIsComplete() {
    let sticker = StickerRow(
      identifier: "EADAA97E-1126-409E-9000-74BD19B39E32",
      shelf: .recent,
      externalURI: "sticker:///user/identifier/EADAA97E-1126-409E-9000-74BD19B39E32",
      name: "BB Test",
      accessibilityName: "teal circle",
      searchText: nil,
      byteCount: 528,
      effect: -1,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastUsedAt: nil,
      libraryIndex: 14336,
      attributionName: "Stickers",
      attributionBundleID: nil,
      representations: [
        StickerRepresentationRow(
          identifier: "5430ECBB-7BEC-461B-97FA-742AF9C5ECE3",
          role: "", uti: "public.png", width: 160, height: 160,
          byteCount: 528, isPreferred: true
        )
      ]
    )
    let json = StickerHandlers.serialize(sticker)

    #expect(json["identifier"]?.stringValue == "EADAA97E-1126-409E-9000-74BD19B39E32")
    #expect(json["shelf"]?.stringValue == "recent")
    #expect(json["kind"]?.stringValue == "user")
    #expect(json["accessibility_name"]?.stringValue == "teal circle")
    // MILLISECONDS, like every other date this API reports.
    #expect(json["created_at"]?.intValue == 1_700_000_000_000)
    // A null rather than an omission, so a client's decoder sees a stable set of keys.
    #expect(json["last_used_at"]?.isNull == true)
    #expect(json["search_text"]?.isNull == true)

    let representation = json["representations"]?.arrayValue?.first
    #expect(representation?["mime_type"]?.stringValue == "image/png")
    #expect(representation?["is_preferred"]?.boolValue == true)
    // A double, because the store keeps non-integral sizes — one representation on this
    // Mac is 900 x 712.555.
    if case .double(let width)? = representation?["width"] {
      #expect(width == 160)
    } else {
      Issue.record("width is not a double")
    }
  }
}
