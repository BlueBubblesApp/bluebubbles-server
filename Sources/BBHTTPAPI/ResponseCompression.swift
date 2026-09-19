//  ResponseCompression
//  gzip on the JSON responses, negotiated, because the wire is the bottleneck and not the CPU.
//
//  MEASURED, on a 421,116-message database over a ~1 Mbit tunnel:
//
//    POST /message/query {"limit": 1000}          1,236,046 bytes   server 137ms   client 10s
//    ... with chats                                1,946,550 bytes   server 428ms   client 16s
//    ... with attributedBody, summary, payload     2,184,800 bytes   server 452ms   client 18s
//
//  Three payloads, three wildly different server costs, and one constant: 0.97-0.99 Mbps.
//  The client was never waiting on this server. It was waiting on the bytes, and there are a
//  lot of them because a message row is mostly text and text is mostly redundant. gzip -6
//  takes this corpus from 1,236,046 to 168,269 bytes (7.3x) for 12ms of CPU, which turns that
//  10 seconds into about 1.4.
//
//  WHY THIS CANNOT BREAK A CLIENT
//  It is CONTENT-NEGOTIATED: nothing is compressed unless the request carried
//  `Accept-Encoding` naming gzip, and a client that does not ask receives exactly the bytes it
//  receives today. That is the whole safety argument, and it is why this ships on by default
//  rather than behind a flag a nobody would find. Every HTTP client library in use here
//  (Dart's `http`, OkHttp, URLSession) decodes `Content-Encoding: gzip` transparently and
//  sends the header without being asked.
//
//  The reference does not compress — there is no `koa-compress` in it, and its only `zlib`
//  use is an opt-in `compress` parameter on a socket route. So this is an ADDITION rather than
//  a divergence: it changes no status code, no envelope key and no error string, and a client
//  that never sends `Accept-Encoding` cannot observe it at all.
//
//  WHAT IS DELIBERATELY NOT COMPRESSED
//    - Anything below `minimumBytes`. Below roughly a kilobyte gzip's own header and the round
//      trip through zlib cost more than the bytes they save, and every error envelope and
//      most single-entity reads live down there.
//    - File and byte-stream responses. `/attachment/:guid/download` serves JPEG, HEIC, PNG,
//      MP4 and CAF, all of which are already compressed: gzip spends CPU to make them very
//      slightly larger. It would also have to buffer the whole file to do it, which is exactly
//      what `FileBodySequence` exists to avoid — a 500MB video must not enter the heap.
//
//  `Vary: Accept-Encoding` goes on every JSON response, compressed or not. Without it a cache
//  in front of the server can hand a compressed body to a client that cannot read one.

import CompressNIO
import Foundation
import NIOCore

public enum ResponseCompression {

  /// Below this, compression costs more than it saves. Measured against the corpus: an error
  /// envelope is ~120 bytes and a `ping` is 55.
  public static let minimumBytes = 1024

  /// zlib level 6. Level 1 is 4.6ms for 5.5x and level 9 is 18.6ms for 7.4x; 6 sits at 12ms
  /// for 7.3x, which is within 2% of level 9's ratio for two-thirds of its cost.
  static let level: Int32 = 6

  /// Whether the request asked for gzip.
  ///
  /// Parsed rather than substring-matched: `Accept-Encoding: gzip;q=0` means "specifically do
  /// NOT send me gzip", and it contains the string "gzip". A client that says that and is sent
  /// gzip anyway is the one failure mode this whole file has to avoid, so `q=0` is honoured.
  public static func accepts(_ header: String?) -> Bool {
    guard let header else { return false }
    for encoding in header.split(separator: ",") {
      let parts = encoding.split(separator: ";")
      let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
      guard name == "gzip" || name == "*" else { continue }

      // A quality of zero is a refusal. Anything else, including an absent q, is assent.
      let quality = parts.dropFirst().compactMap { parameter -> Double? in
        let pair = parameter.split(separator: "=", maxSplits: 1)
        guard pair.count == 2,
          pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "q"
        else { return nil }
        return Double(pair[1].trimmingCharacters(in: .whitespaces))
      }.first
      if let quality, quality == 0 { continue }
      return true
    }
    return false
  }

  /// Compresses a JSON body, or hands back what it was given.
  ///
  /// Returns nil when the body should go out uncompressed — too small, or zlib refused it.
  /// A refusal is not an error: the uncompressed body is always correct, so a failure here
  /// degrades to today's behaviour rather than to a 500.
  static func gzip(_ data: Data) -> ByteBuffer? {
    guard data.count >= minimumBytes else { return nil }
    var source = ByteBuffer(data: data)
    return try? source.compress(
      with: .gzip(configuration: .init(compressionLevel: level))
    )
  }
}
