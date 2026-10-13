//  SecretsEnvelope
//  The only way secrets leave this server, and the reason they can.
//
//  **The server password is both the gate and the key.** Exporting secrets requires typing
//  the password this server accepts, and the archive is encrypted with a key
//  derived from it. That is one decision doing two jobs on purpose:
//
//    - it proves the person exporting already has the credential that owns the server, so
//      the export grants them nothing they did not have;
//    - and it means the file is useless to whoever finds it later, which matters because a
//      ZIP is a thing people email themselves and leave in Downloads.
//
//  **A server with no password cannot export secrets at all.** Not "exports them in the
//  clear", not "asks for a different passphrase": refused. An empty password is the shipped
//  default and the state a fresh install sits in, so allowing it would mean the least
//  configured servers produce the most dangerous files. `PasswordPolicy` exempts the empty
//  string for its own good reasons; this is where that exemption stops.
//
//  The iteration count is stored in each envelope rather than assumed, so raising it does
//  not strand archives written under the old one. It is READ from a file that came from
//  outside this server, though, so `open` holds it to `acceptedIterations` before deriving
//  anything: a crafted archive asking for two billion rounds would hold an import for hours
//  on the hardware this targets, and one asking for a single round would be accepted as if
//  it were protection.
//
//  PBKDF2 rather than HKDF, and this is the distinction that matters when a KEY comes from
//  a PASSWORD: HKDF is a fast extract-and-expand over material that is already
//  high-entropy, and applying it to something a person typed hands an attacker an offline
//  guessing oracle at the speed of a hash. PBKDF2's work factor is the whole point. The salt
//  is random per export, so two exports of the same server under the same password do not
//  produce the same key.

import BBCore
import Crypto
import Foundation
import _CryptoExtras

/// The encrypted `secrets.enc` member of an archive.
public struct SecretsEnvelope: Codable, Sendable {

  /// Bumped if the derivation or the cipher changes. An envelope from a future version is
  /// refused rather than attempted; see `open`.
  public static let currentVersion = 1

  /// Named in the file rather than implied by the version, so somebody reading an archive
  /// later can see what they are holding without this source.
  public static let algorithm = "PBKDF2-HMAC-SHA256+AES-256-GCM"

  /// 210,000, the OWASP floor for PBKDF2-HMAC-SHA256.
  ///
  /// Stored in the file rather than assumed, so raising it later does not strand archives
  /// made under the old count: `open` uses whatever the envelope says.
  public static let iterations = 210_000

  /// The counts `open` will derive a key with.
  ///
  /// From what this server writes up to ten times it, which leaves room for the count to be
  /// raised (OWASP's current figure is 600,000) without stranding archives, and keeps the
  /// worst case an archive can ask for at a few seconds of an import rather than hours. Below
  /// the floor is no archive this server ever wrote.
  public static let acceptedIterations = iterations...(iterations * 10)

  public let version: Int
  public let algorithm: String
  public let iterations: Int
  /// Base64. Random per export, so the same password over the same server twice yields two
  /// different keys.
  public let salt: Data
  public let nonce: Data
  public let ciphertext: Data
  public let tag: Data

  public enum Failure: BBError, Equatable, CustomStringConvertible {
    /// This server has no password, so there is nothing to gate the export with.
    case noServerPassword
    /// The password given is not the one this server accepts.
    case wrongPassword
    /// The archive was written by a newer version of this format.
    case unsupportedVersion(Int)
    /// The password was right for the gate but the envelope will not open, which means the
    /// file has been altered or truncated.
    case corrupt
    /// The envelope asks for a key-derivation count outside `acceptedIterations`: no export
    /// of this format carries one, so the file was made or edited by something else.
    case implausibleIterations(Int)
    /// The system's secure random generator refused, so there is no salt to seal with.
    /// Carries the `OSStatus`.
    case randomUnavailable(Int32)

    public var code: String {
      switch self {
      case .noServerPassword: "export.no_server_password"
      case .wrongPassword: "export.wrong_password"
      case .unsupportedVersion: "export.unsupported_secrets_version"
      case .corrupt: "export.secrets_corrupt"
      case .implausibleIterations: "export.secrets_implausible_iterations"
      case .randomUnavailable: "export.random_unavailable"
      }
    }
    public var domain: String { "Export" }
    public var title: String { "The passwords and keys could not be read" }
    /// The CLI prints this, so it is the same sentence the app shows.
    public var description: String { body }

    public var body: String {
      switch self {
      case .noServerPassword:
        "This server has no password, so secrets cannot be exported. Set a server password "
          + "first: it is what the export is encrypted with."
      case .wrongPassword:
        "That is not this server's password."
      case .unsupportedVersion(let version):
        "This archive's secrets were written by a newer version of BlueBubbles (format "
          + "\(version)). Update before importing it."
      case .corrupt:
        "The password was accepted but the encrypted section could not be read. The file is "
          + "damaged or was modified after it was made."
      case .implausibleIterations(let count):
        "This archive's encrypted section asks for \(count) key-derivation rounds, which no "
          + "BlueBubbles export uses. The file was not made by this app or was modified."
      case .randomUnavailable(let status):
        "macOS could not provide secure random bytes to encrypt the export with (status "
          + "\(status)). Nothing was written; try again."
      }
    }
  }

  /// Encrypts `payload` under a key derived from the server password.
  ///
  /// - Parameter password: the password this server accepts. Refused when empty;
  ///   see the header.
  public static func seal(_ payload: Data, withServerPassword password: String) throws
    -> SecretsEnvelope
  {
    try seal(payload, withServerPassword: password, randomBytes: systemRandomBytes)
  }

  /// Fills a buffer from the system's CSPRNG and answers its status.
  ///
  /// The system generator, not `SystemRandomNumberGenerator` over a loop: this is key
  /// material and the platform's CSPRNG is the thing to ask.
  static func systemRandomBytes(_ buffer: UnsafeMutableRawBufferPointer) -> OSStatus {
    guard let base = buffer.baseAddress else { return errSecAllocate }
    return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
  }

  /// `seal` with the random source named, so a test can make it refuse.
  static func seal(
    _ payload: Data, withServerPassword password: String,
    randomBytes: (UnsafeMutableRawBufferPointer) -> OSStatus
  ) throws -> SecretsEnvelope {
    guard !password.isEmpty else { throw Failure.noServerPassword }

    // The status is CHECKED: a refusal leaves the buffer as it was, all zeroes, and sealing
    // under a zero salt would write a file that looks protected and derives the same key as
    // every other such file sealed under the same password.
    var salt = Data(count: 32)
    let status = salt.withUnsafeMutableBytes(randomBytes)
    guard status == errSecSuccess else { throw Failure.randomUnavailable(status) }

    let key = try derive(password: password, salt: salt, iterations: iterations)
    let sealed = try AES.GCM.seal(payload, using: key)
    return SecretsEnvelope(
      version: currentVersion,
      algorithm: algorithm,
      iterations: iterations,
      salt: salt,
      nonce: Data(sealed.nonce),
      ciphertext: sealed.ciphertext,
      tag: sealed.tag
    )
  }

  /// Decrypts, or says which of the three things went wrong.
  ///
  /// A wrong password and a damaged file are told apart by the CALLER having already
  /// checked the password against this server, because AES-GCM cannot distinguish them: a
  /// bad key and a bad ciphertext both fail the tag. `ServerImporter` does that check, which
  /// is what lets the message say "that is not the password" rather than "it did not work".
  public func open(withPassword password: String) throws -> Data {
    guard version <= Self.currentVersion else {
      throw Failure.unsupportedVersion(version)
    }
    // Before the derivation, which is the expensive part: the count is the file's to state
    // and this server's to bound. See the header.
    guard Self.acceptedIterations.contains(iterations) else {
      throw Failure.implausibleIterations(iterations)
    }
    let key = try Self.derive(password: password, salt: salt, iterations: iterations)
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
      return try AES.GCM.open(box, using: key)
    } catch {
      throw Failure.corrupt
    }
  }

  private static func derive(password: String, salt: Data, iterations: Int) throws
    -> SymmetricKey
  {
    try KDF.Insecure.PBKDF2.deriveKey(
      from: Data(password.utf8),
      salt: salt,
      using: .sha256,
      outputByteCount: 32,
      rounds: iterations
    )
  }
}
