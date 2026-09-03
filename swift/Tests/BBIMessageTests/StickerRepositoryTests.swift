//  StickerRepositoryTests
//  The parts of the sticker store's reader that do not need the store.
//
//  The queries themselves are exercised against a live Mac rather than here: there is no
//  fixture `stickers.stickerdb` and building one would mean reproducing a Core Data +
//  CloudKit schema Apple owns, which would pin the shape of the fake rather than of the
//  real thing. What IS testable in isolation is everything an identifier or an external
//  URI goes through on its way in and out, and that is where the bugs were — a client
//  sending a dashed UUID against a column holding raw blob bytes has to normalise
//  somewhere.

import Foundation
import Testing

@testable import BBIMessage

@Suite("Sticker store")
struct StickerRepositoryTests {

  @Test("A dashed UUID and bare hex normalise to the same query value")
  func identifiersNormalise() {
    // The column is a 16-byte BLOB, matched against `hex()`, so both spellings a client
    // might send have to arrive as the same 32 uppercase characters.
    let dashed = "AC20781C-5A31-40D9-8931-3619AA9783C9"
    let bare = "ac20781c5a3140d989313619aa9783c9"
    #expect(StickerRepository.hex(dashed) == "AC20781C5A3140D989313619AA9783C9")
    #expect(StickerRepository.hex(bare) == StickerRepository.hex(dashed))
  }

  @Test("A malformed identifier is rejected rather than queried")
  func malformedIdentifiersAreRejected() {
    // Nil is what turns a bad id into a 404 instead of a query with a nonsense argument.
    #expect(StickerRepository.hex("") == nil)
    #expect(StickerRepository.hex("not-a-uuid") == nil)
    // Right length, wrong alphabet — the case that a length check alone would let through.
    #expect(StickerRepository.hex("ZZ20781C5A3140D989313619AA9783C9") == nil)
    // One character short of a UUID.
    #expect(StickerRepository.hex("AC20781C-5A31-40D9-8931-3619AA9783C") == nil)
  }

  @Test("Blob hex comes back out as a dashed UUID")
  func identifiersRoundTrip() {
    // A client should never see raw blob hex: the identifier it reads is the identifier it
    // sends back, in the shape every other identifier in this API has.
    let hex = "7608FF1D006B4E00B15ADDB5001BCBF6"
    #expect(StickerRepository.uuid(hex) == "7608FF1D-006B-4E00-B15A-DDB5001BCBF6")
    #expect(StickerRepository.hex(StickerRepository.uuid(hex) ?? "") == hex)
    #expect(StickerRepository.uuid("short") == nil)
  }

  @Test("Each shelf maps to exactly one stored type, and back")
  func shelvesMapBothWays() {
    // The mapping was read off a live store (see `StickerShelf`) and then confirmed by
    // donating a sticker, which produced a type-0 row. Pinned so a later reading of the
    // schema cannot silently swap them: `saved` and `recent` are what a client filters on.
    #expect(StickerShelf.recent.storedType == 0)
    #expect(StickerShelf.saved.storedType == 1)
    for shelf in StickerShelf.allCases {
      #expect(StickerShelf.shelf(forStoredType: shelf.storedType) == shelf)
    }
    // A type Apple adds later is not silently folded into one of ours.
    #expect(StickerShelf.shelf(forStoredType: 2) == nil)
    #expect(StickerShelf.shelf(forStoredType: -1) == nil)
  }

  @Test("The store's own path is under the stickersd group container")
  func defaultPathIsTheGroupContainer() {
    let path = StickerRepository.defaultPath(home: URL(fileURLWithPath: "/Users/example"))
    #expect(
      path == "/Users/example/Library/Group Containers/com.apple.stickersd.group"
        + "/Stickers/stickers.stickerdb")
  }
}
