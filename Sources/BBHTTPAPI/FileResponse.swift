//  FileResponse
//  The two halves of a `.file` response: its `Content-Disposition` header and the stream that
//  reads it off disk.
//
//  Clients observe both: the quoted filename is what they save the download as, and the
//  `Content-Length` they read for a progress bar comes from `FileBodySequence.size`.

import BBCore
import Foundation
import NIOCore
import NIOPosix

// MARK: - Content-Disposition

/// The `Content-Disposition` header for a file download.
///
/// **The filename is not ours.** `transfer_name` comes out of `chat.db`, and for an incoming
/// attachment it is the name the SENDER's device chose — so a quote in it used to close the
/// quoted-string early and produce `filename="My "quoted" clip.mov"`, which a client parses as
/// `My `. Not a response split: `swift-http-types` legalizes a field value, so a CR or LF is
/// replaced with a space long before it reaches a socket. A truncated or wrong filename is the
/// whole of the damage, and it is enough to fix.
///
/// **Every byte of the header is printable ASCII.** A field value is not a UTF-8 string:
/// RFC 9110 leaves a byte above 0x7F as opaque `obs-text`, which a recipient may decode as
/// Latin-1, reject, or pass through. `HTTPField` writes a Swift string's UTF-8 bytes out
/// unchanged, so a raw non-ASCII name was never a failed request here, only a name each
/// recipient read differently.
///
/// Two parameters, per RFC 6266, and the second one **only when the name is not ASCII**:
///
///   - `filename=` is the quoted form every shipped client reads, with `\` and `"` escaped as
///     RFC 2616 quoted-pair and control characters dropped. For a non-ASCII name it carries
///     `asciiFallback(for:)`, never the raw bytes: RFC 6266 Appendix D tells a sender to keep
///     this parameter to a portable subset and put the real name in `filename*`.
///   - `filename*=UTF-8''…` carries the real bytes, percent-encoded, so it is ASCII too. It is
///     omitted for an ASCII name, so the header for an ordinary attachment is byte-identical
///     to what the reference sends and to what every recorded fixture holds.
public enum ContentDisposition {

  public static func header(filename: String) -> String {
    guard !filename.allSatisfy(\.isASCII) else {
      return "attachment; filename=\"\(quotedForm(of: filename))\""
    }
    let named = String(
      String.UnicodeScalarView(
        filename.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
    return "attachment; filename=\"\(quotedForm(of: asciiFallback(for: named)))\""
      + "; filename*=UTF-8''\(extendedForm(of: named))"
  }

  /// The name a recipient that ignores `filename*` saves under: as close to the real one as
  /// ASCII gets, so `Ünicöde.jpg` falls back to `Unicode.jpg` rather than `_nic_de.jpg`.
  ///
  /// ICU's `Latin-ASCII` does the folding and leaves what it has no rule for, which includes
  /// U+202F and every emoji, so a scalar pass finishes the job: Unicode whitespace becomes a
  /// space, anything else still outside ASCII becomes `_`. The result may hold `"` (from a
  /// curly quote) or `\`, which `quotedForm(of:)` escapes after this.
  static func asciiFallback(for filename: String) -> String {
    let folded =
      filename.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false)
      ?? filename
    var out = ""
    for scalar in folded.unicodeScalars {
      if scalar.isASCII {
        out.unicodeScalars.append(scalar)
      } else {
        out.append(scalar.properties.isWhitespace ? " " : "_")
      }
    }
    return out
  }

  /// The quoted-string body: control characters dropped, `\` and `"` escaped.
  ///
  /// Dropped rather than escaped for the controls, because there is no quoted-pair spelling a
  /// client would render usefully and a filename never legitimately contains one.
  static func quotedForm(of filename: String) -> String {
    var out = ""
    for scalar in filename.unicodeScalars {
      switch scalar {
      case "\\", "\"":
        out.append("\\")
        out.unicodeScalars.append(scalar)
      default:
        guard !CharacterSet.controlCharacters.contains(scalar) else { continue }
        out.unicodeScalars.append(scalar)
      }
    }
    return out
  }

  /// RFC 5987 `ext-value`: percent-encoded UTF-8, keeping only `attr-char`.
  ///
  /// Hand-rolled rather than `addingPercentEncoding(withAllowedCharacters:)`, because that
  /// takes an ALLOWED set and RFC 5987's is narrower than any of the URL sets Foundation
  /// ships: `CharacterSet.urlQueryAllowed` passes `&`, `=` and `;` straight through, and a
  /// `;` in a filename would start a parameter of its own.
  static func extendedForm(of filename: String) -> String {
    let unreserved = Set(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&+-.^_`|~".utf8)
    var out = ""
    for byte in Array(filename.utf8) {
      if unreserved.contains(byte) {
        out.unicodeScalars.append(UnicodeScalar(byte))
      } else {
        out += String(format: "%%%02X", byte)
      }
    }
    return out
  }
}

// MARK: - File streaming

/// Streams a file in fixed-size chunks, off the request executor.
///
/// NOT NIO's `FileRegion`/`sendfile` path: these bytes pass through the heap. The contract
/// this keeps is that peak memory is the CHUNK size and not the file size, which is true of
/// both mechanisms and is the thing that matters; the file's own comment used to claim
/// sendfile in one place and deny it in another.
///
/// Reads run on the NIO thread pool rather than inline. `read(2)` is a blocking syscall, and
/// a 500MB download issues about eight thousand of them: inline, each one parks a cooperative
/// thread until the disk answers, and the runtime's answer to that is to make more threads.
/// Measured elsewhere in this audit: 64 concurrent blocking tasks grew the pool to 58 threads,
/// about 30MB of stacks on a machine that may have 4GB. A spinning disk makes each of those
/// waits far longer.
///
/// `pread` rather than a `FileHandle`: it takes the offset as an argument instead of keeping
/// one on a shared object, so the iterator carries nothing across threads but an integer, and
/// `FileHandle` is not `Sendable`.
struct FileBodySequence: AsyncSequence, Sendable {
  typealias Element = ByteBuffer

  let file: OpenFile
  let chunkSize: Int = 64 * 1024

  /// A stream over whatever `path` names, opened now. A file that cannot be opened streams
  /// nothing; the response path uses `opening(_:)` instead, which refuses one.
  init(path: String) {
    self.file = OpenFile(path: path)
  }

  private init(file: OpenFile) {
    self.file = file
  }

  /// The stream a `.file` response sends, and the length it promises, or the error that
  /// response must be instead.
  ///
  /// Opened BEFORE the status is chosen. Opened lazily, inside the body, a file that had
  /// vanished since the route checked it (an attachment purged to iCloud) was answered with a
  /// 200 and no body: the status was already on the wire when the open failed, so the client
  /// saw a successful, empty download. The size comes from `fstat` on the open descriptor,
  /// so the `Content-Length` describes the file actually being sent.
  ///
  /// Every failure is a 500 `Server Error`, a missing file included, because that is what the
  /// reference sends for every route that streams a file: its `FileStream` calls
  /// `fs.statSync(path)` in the constructor (`responses/success.ts:91`), which throws on a
  /// missing path, and `errorMiddleware.ts` answers anything that is not an `HTTPError` with a
  /// 500 and `ErrorTypes.SERVER_ERROR`. The detail says which failure it was.
  static func opening(_ path: String) throws -> (body: FileBodySequence, size: Int64) {
    let file = OpenFile(path: path)
    guard file.descriptor >= 0 else {
      switch file.openError {
      case ENOENT, ENOTDIR: throw ServerError("The file to send no longer exists on disk.")
      default:
        throw ServerError(
          "The file to send could not be opened: \(String(cString: strerror(file.openError))).")
      }
    }
    var status = stat()
    guard fstat(file.descriptor, &status) == 0 else {
      throw ServerError(
        "The file to send could not be read: \(String(cString: strerror(errno))).")
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
      throw ServerError("The path to send is not a regular file.")
    }
    return (FileBodySequence(file: file), Int64(status.st_size))
  }

  /// What a read failed with, as distinct from reaching the end.
  struct ReadFailure: BBError {
    let errorNumber: CInt
    var code: String { "http.file_read_failed" }
    var domain: String { "HTTP" }
    var title: String { "A file could not be sent" }
    var body: String {
      "The file could not be read: \(String(cString: strerror(errorNumber)))."
    }
  }

  /// Owns the descriptor, so abandoning the stream closes it.
  ///
  /// A class, and this is the whole reason for one: the iterator is a struct, and a struct
  /// holding a raw descriptor has nowhere to put a `deinit`. A client that disconnects
  /// mid-download abandons the sequence without reaching the end, and every one of those
  /// leaked a descriptor -- measured at exactly one per abandoned download, until the
  /// process runs out and can no longer open a socket or the database. `FileHandle`, which
  /// this replaced, closed on dealloc and did not have the problem.
  ///
  /// Shared by every iterator of one sequence, which is safe because each reads with `pread`
  /// at an offset of its own.
  final class OpenFile: Sendable {
    let descriptor: CInt
    /// The `errno` the open failed with, or zero when it succeeded.
    let openError: CInt

    init(path: String) {
      let opened = open(path, O_RDONLY)
      descriptor = opened
      openError = opened >= 0 ? 0 : errno
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
  }

  struct AsyncIterator: AsyncIteratorProtocol {
    let file: OpenFile
    let chunkSize: Int
    var offset: off_t = 0
    var isFinished = false

    mutating func next() async throws -> ByteBuffer? {
      // A response never reaches here with an unopened file: `opening(_:)` refuses one before
      // the status is chosen. A sequence built with `init(path:)` can, and it ends the
      // stream rather than trapping.
      guard file.descriptor >= 0, !isFinished else { return nil }
      let start = offset
      let size = chunkSize
      let descriptor = file.descriptor
      let bytes = try await NIOThreadPool.singleton.runIfActive { () -> [UInt8] in
        var buffer = [UInt8](repeating: 0, count: size)
        while true {
          let read = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return pread(descriptor, base, size, start)
          }
          // A FAILURE is not the end of the file, and conflating them is how a download
          // silently truncates. `read < 0` means errno: `EINTR` is a signal arriving
          // mid-read and is simply retried, anything else is real and is thrown, so the
          // response fails visibly rather than ending short of the Content-Length it
          // already promised.
          if read < 0 {
            if errno == EINTR { continue }
            throw ReadFailure(errorNumber: errno)
          }
          if read == 0 { return [] }
          buffer.removeLast(size - read)
          return buffer
        }
      }
      guard !bytes.isEmpty else {
        isFinished = true
        return nil
      }
      offset += off_t(bytes.count)
      return ByteBuffer(bytes: bytes)
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(file: file, chunkSize: chunkSize)
  }
}
