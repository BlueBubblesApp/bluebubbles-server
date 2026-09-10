//  HandleInterface
//  Handle operations: the addresses on the other end of a conversation.

import BBCore
import BBIMessage
import BBPrivateAPIContract
import BBSerialization
import Foundation
import Logging

public struct HandleInterface: MessagesBackedInterface {

  private let repository: MessageRepository
  /// The roles this interface calls, and no more.
  public typealias Helper = any HandleAvailability

  let privateAPI: Helper?
  let logger: Logger

  public init(
    repository: MessageRepository,
    privateAPI: Helper? = nil,
    logger: Logger = Logger(label: "bluebubbles.interface.handle")
  ) {
    self.repository = repository
    self.privateAPI = privateAPI
    self.logger = logger
  }

  /// The largest page a handle query answers.
  ///
  /// The reference refuses a `limit` outside 1…1000 (`handleValidator.ts`:
  /// `limit: "numeric|min:1|max:1000"`). This server has no validation layer, so the same
  /// range is applied by folding the request into it, as `MessageQuery` does; before this,
  /// whatever a client sent reached `LIMIT ?` unchanged, negative or a million.
  public static let maximumPageSize = 1000

  /// `limit` and `offset` folded into the range the query will actually run with. The
  /// handler echoes THESE in its metadata, so a client that asked for more sees what it got.
  public static func clampedPage(limit: Int, offset: Int) -> (limit: Int, offset: Int) {
    (limit: min(max(1, limit), maximumPageSize), offset: max(0, offset))
  }

  public func query(limit: Int = 1000, offset: Int = 0) async throws -> [HandleRow] {
    let page = Self.clampedPage(limit: limit, offset: offset)
    return try await repository.handles(limit: page.limit, offset: page.offset)
  }

  public func count() async throws -> Int {
    try await repository.handleCount()
  }

  /// A handle and, when they were asked for, the chats it belongs to.
  public struct HandleProjection: Sendable {
    public let row: HandleRow
    /// Nil when the caller did not ask for them, which is DISTINCT from an empty array:
    /// a handle that genuinely belongs to no chat. The wire format omits the key entirely
    /// in the first case and emits `[]` in the second, so collapsing the two into one
    /// empty array would change the response.
    public let chats: [ChatRow]?
  }

  public func find(
    address: String, withChats: Bool = false
  ) async throws -> HandleProjection? {
    guard let handle = try await repository.handle(address: address) else { return nil }
    return HandleProjection(
      row: handle,
      chats: withChats ? try await repository.chats(forHandleRowID: handle.rowID) : nil
    )
  }

  public func serialize(_ row: HandleRow) -> JSONValue {
    HandleSerializer.serialize(row)
  }

  public func serialize(_ projection: HandleProjection) -> JSONValue {
    let object = HandleSerializer.serialize(projection.row)
    guard let chats = projection.chats else { return object }
    return object.merging([
      "chats": .array(chats.map { ChatSerializer.serialize($0, includeParticipants: false) })
    ])
  }

  /// Whether an address can be reached on a service.
  ///
  /// Needs the Private API: availability is a live lookup against Apple's IDS, not
  /// anything chat.db records. A handle row proves someone was reachable once, which is a
  /// different question, and the one clients keep mistaking for this one.
  public func availability(address: String, service: HandleService) async throws -> Bool {
    let api = try requirePrivateAPI(for: "checking address availability")
    return try await throughMessages {
      switch service {
      case .iMessage: try await api.checkIMessageAvailability(address: address)
      case .faceTime: try await api.checkFaceTimeAvailability(address: address)
      }
    }
  }

  /// The contact's Focus state, as a raw string from IMCore.
  ///
  /// Not an enum: the values come from Apple and new ones appear between releases, so a
  /// closed set here would turn an unknown-but-harmless status into a decode failure.
  public func focusStatus(address: String) async throws -> String {
    let api = try requirePrivateAPI(for: "reading Focus status")
    return try await throughMessages { try await api.checkFocusStatus(address: address) }
  }
}

public enum HandleService: String, Sendable {
  case iMessage
  case faceTime

  /// Parses the spelling clients send, which is not consistent: `iMessage`, `imessage`
  /// and `FaceTime` all appear in the wild.
  public init?(wire: String) {
    switch wire.lowercased() {
    case "imessage": self = .iMessage
    case "facetime": self = .faceTime
    default: return nil
    }
  }
}
