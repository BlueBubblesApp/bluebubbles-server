//  AppPreviewImageTests
//  What a client may hand over as an app balloon's image, checked before anything is staged.
//
//  The image is sent to every recipient as an attachment, so the check is the only thing
//  between a client's mistake and a stranger's phone downloading it: a file that is not an
//  image the recipient's extension can show, or a full-resolution photo where a thumbnail was
//  meant. Each is refused as a 400 with the reason, before Messages is asked.

import Foundation
import Testing

@testable import BBInterfaces

@Suite("App preview image")
struct AppPreviewImageTests {

  private typealias Image = MessageInterface.AppPreviewImage

  private static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
  private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

  /// The opening of a HEIC file: a box length, then `ftyp` and its brand.
  private static let heic = Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypheic".utf8) + Data(count: 4)

  @Test("A JPEG, a PNG and a HEIC are accepted and named by what they are")
  func acceptsAll() throws {
    #expect(try Image(data: Self.jpeg).fileExtension == "jpeg")
    #expect(try Image(data: Self.png).fileExtension == "png")
    // What Game Pigeon itself attaches.
    #expect(try Image(data: Self.heic).fileExtension == "heic")
  }

  @Test("Base64 is read with or without a data URL prefix")
  func base64Forms() throws {
    let encoded = Self.jpeg.base64EncodedString()
    #expect(try Image(base64: encoded).data == Self.jpeg)
    #expect(try Image(base64: "data:image/jpeg;base64," + encoded).data == Self.jpeg)
  }

  @Test(
    "Anything else is refused as a bad request",
    arguments: [
      Data(), Data("GIF89a".utf8), Data("<svg/>".utf8),
      Data(repeating: 0xFF, count: 2),
      // An MP4 opens with an `ftyp` box too; only the HEIF brands are images.
      Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypisom".utf8) + Data(count: 4),
    ])
  func refusesOthers(_ data: Data) {
    #expect(throws: InterfaceError.self) { try Image(data: data) }
  }

  @Test("Text that is not base64 is refused, not read as empty")
  func refusesBadBase64() {
    #expect(throws: InterfaceError.self) { try Image(base64: "!!!") }
  }

  @Test("An image over the cap is refused, naming the cap")
  func refusesOversize() {
    let oversized = Self.jpeg + Data(count: Image.maximumBytes)
    do {
      _ = try Image(data: oversized)
      Issue.record("an oversized image should be refused")
    } catch let error as InterfaceError {
      guard case .invalidRequest(let reason) = error else {
        Issue.record("expected invalidRequest, got \(error)")
        return
      }
      #expect(reason.contains("\(Image.maximumBytes)"))
    } catch {
      Issue.record("expected an InterfaceError, got \(error)")
    }
  }
}
