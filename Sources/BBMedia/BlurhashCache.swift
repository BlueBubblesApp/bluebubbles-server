//  BlurhashCache
//  Blurhashes, remembered across requests.
//
//  A client rendering a conversation asks for a placeholder per image, and asks again every
//  time the view is rebuilt. Nothing cached them at any layer, so a gallery of a hundred
//  photos decoded and hashed all hundred on every open.
//
//  The transform itself is no longer the cost -- a 512-pixel box at 9x9 components went from
//  438ms to 15ms -- so what a repeat request pays is the DECODE: a 12-megapixel HEIC read off
//  disk and scaled down, tens of milliseconds here and several times that on a 2012-2017 Mac
//  with no hardware HEVC decoder.
//
//  Bounded, and bounded for the same reason `AttachmentMetadataReader` is: the key is
//  attacker-paced, and an unbounded dictionary on an actor that lives for the whole process
//  grows with every attachment a client scrolls past.

import BBCore
import Foundation

public actor BlurhashCache {

  /// A hash is only the same answer for the same image AND the same parameters: the
  /// component counts are encoded in the hash string itself, and the downsample box changes
  /// the pixels the transform sees.
  public struct Key: Hashable, Sendable {
    let guid: String
    let componentsX: Int
    let componentsY: Int
    let maximumEdge: Int

    public init(guid: String, componentsX: Int, componentsY: Int, maximumEdge: Int) {
      self.guid = guid
      self.componentsX = componentsX
      self.componentsY = componentsY
      self.maximumEdge = maximumEdge
    }
  }

  private var cache: BoundedCache<Key, String>

  /// A hash is about thirty characters, so a thousand of them is tens of kilobytes -- far
  /// below anything the memory budget cares about, and far above what one conversation
  /// touches.
  public init(capacity: Int = 1024) {
    cache = BoundedCache(capacity: capacity)
  }

  public func hash(for key: Key) -> String? { cache[key] }

  public func remember(_ hash: String, for key: Key) { cache[key] = hash }

  /// How many are held. For the test that pins the bound.
  var count: Int { cache.count }
}
