//  MessageFilter
//  The `where` clause on `POST /message/query`, as typed predicates rather than SQL.
//
//  **What this replaces: nothing.** `where` was accepted by the route, parsed by nobody and
//  applied to neither the listing nor its count, so a client filtering on it received the
//  newest `limit` messages in the database and a `total` counting every message there is.
//  The app's incremental sync is built on exactly that filter (`message.ROWID > :startRowId`),
//  so on a large database it read page after page of messages it already had, never saw the
//  empty page that ends the loop, and timed out. Measured on a 420,679-message chat.db:
//  `ROWID > max-5` returned 1000 rows and a total of 416,939 where the answer is 5 and 5.
//
//  **Why typed cases and not the reference's SQL passthrough.** The reference splices the
//  client's own `statement` into its WHERE with bound arguments, which hands an authenticated
//  client arbitrary SQL against `chat.db`: subqueries, `sqlite_master`, whatever the next
//  SQLite release adds to the expression grammar. That is a wire behaviour no client can
//  observe (a client sends one of eight statements and reads back rows), so the contract is
//  the FILTERING, not the mechanism, and reproducing the mechanism buys nothing but the risk.
//  → `.claude/docs/decisions.md`, and the rule about what the contract does not constrain.
//
//  The eight cases below are every statement the BlueBubbles client sends, transcribed from
//  it rather than imagined: `search_query_helper.dart` (five), `incremental_sync_manager.dart`
//  (two) and `api_payload_parser.dart` (one). A statement outside the set is REFUSED, with the
//  statement quoted back. Silently ignoring it is what this file exists to fix, and answering
//  a filter nobody applied with a 200 is the same bug wearing different syntax.
//
//  See `.claude/docs/api.md`.

import BBCore
import Foundation

/// One `{statement, args}` pair from a client, understood.
public enum MessageFilter: Sendable, Equatable {

  /// `message.ROWID > :x` and `message.ROWID <= :x`, the two the incremental sync sends.
  ///
  /// Both bounds exist because the sync pages a fixed window: it pins the top with `<=` so
  /// messages arriving mid-sync do not shift the pages under it.
  case rowIDGreaterThan(Int64)
  case rowIDAtMost(Int64)

  /// `message.is_from_me = :x`.
  case isFromMe(Bool)

  /// `message.text LIKE :term COLLATE NOCASE`, with the wildcards the client wrote.
  ///
  /// **Matches the COLUMN, which on Ventura and newer is null for most outgoing messages**:
  /// the words live in `attributedBody` and nowhere a SQL `LIKE` can reach. That is the
  /// reference's behaviour too, and it is why the reference reroutes text search through
  /// Spotlight when the Private API is available (`searchMessagesPrivateApi`). Reproducing
  /// the column match is parity; the Spotlight path is a separate piece of work, and until
  /// it exists an outgoing message will not be found by its text.
  case textLike(String)

  /// `message.guid IN (:...guids)`. The client hydrating notification payloads sends this.
  case guidIn([String])

  /// `message.associated_message_guid IS NULL`: exclude reactions and replies from a search.
  case notAssociated

  /// `chat.guid = :guid`, scoping a search to one conversation.
  ///
  /// Resolved through `ChatGUID.lookupCandidates()`, never compared with `=`: a chat GUID
  /// differs between servers on one iCloud account and macOS 26 rewrote every prefix to
  /// `any`. See the root `CLAUDE.md`, rule 3.
  case chatGUID(String)

  /// `handle.id = :addr`, scoping a search to one correspondent.
  case handleAddress(String)
}

/// One bound argument from a `where` clause, in the three shapes clients send.
///
/// Not `JSONValue`: that type lives in BBSerialization, which is the WIRE layer, and this
/// target sits below it. The adaptation from JSON is one function in `BBInterfaces`, which
/// has both; keeping it out of here is what stops `chat.db` reading from depending on the
/// shape of an HTTP body.
public enum FilterArgument: Sendable, Equatable {
  case number(Int64)
  case text(String)
  case list([String])
}

extension MessageFilter {

  /// A statement this server will not run.
  ///
  /// Carries the statement so the message can quote it: a client author who sends something
  /// new needs to know WHICH of their clauses was refused, and a generic "unsupported filter"
  /// on a request carrying four of them tells them nothing.
  public struct Unsupported: Error, Equatable, Sendable {
    public let statement: String
    public init(statement: String) { self.statement = statement }
  }

  /// Parses one `{statement, args}` pair.
  ///
  /// Matched on the SHAPE (column, operator, and whether a placeholder follows) rather than
  /// on the exact string, so a client that names its placeholder `:since` instead of
  /// `:startRowId`, or writes `message.ROWID>:x` without spaces, still works. The argument is
  /// then read by that placeholder's own name, which is how the reference binds it.
  ///
  /// - Parameters:
  ///   - statement: the raw statement text.
  ///   - arguments: the pair's `args`, by placeholder name. Empty for a statement that
  ///     takes none, which is what the client sends for `IS NULL`.
  public static func parse(
    statement raw: String,
    arguments: [String: FilterArgument]
  ) throws -> MessageFilter {
    let statement = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    // Reduced to shape: every `:placeholder` (and TypeORM's `:...spread`) becomes `?`, the
    // operators are spaced so `ROWID>:x` and `ROWID > :x` normalize alike, and the result is
    // lowercased. Matching the raw text instead would tie this to the placeholder NAMES the
    // current client happens to use, and a client calling its bound value `:since` rather
    // than `:startRowId` means exactly the same query.
    var normalized = ""
    var placeholders: [String] = []
    var rest = Substring(statement)
    while let colon = rest.firstIndex(of: ":") {
      normalized += rest[..<colon]
      let after = rest[rest.index(after: colon)...].drop(while: { $0 == "." })
      let name = after.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
      if name.isEmpty {
        // A stray colon is not a placeholder. Kept, so it cannot match by accident.
        normalized += ":"
        rest = rest[rest.index(after: colon)...]
      } else {
        placeholders.append(String(name))
        normalized += "?"
        rest = after[name.endIndex...]
      }
    }
    normalized += rest

    normalized =
      normalized
      .lowercased()
      .replacingOccurrences(of: "(", with: " ( ")
      .replacingOccurrences(of: ")", with: " ) ")
      .replacingOccurrences(of: "<=", with: " <= ")
      .replacingOccurrences(of: ">=", with: " >= ")
      .replacingOccurrences(of: ">", with: " > ")
      .replacingOccurrences(of: "<", with: " < ")
      .replacingOccurrences(of: "=", with: " = ")
      // The two-character operators are re-split by the single-character passes above.
      .replacingOccurrences(of: "<  = ", with: "<= ")
      .replacingOccurrences(of: ">  = ", with: ">= ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")

    func value() throws -> FilterArgument {
      // The LAST placeholder, because the statements that carry trailing words after one
      // (`LIKE ? COLLATE NOCASE`) never carry two, and taking the first would be wrong the
      // day a clause does.
      guard let name = placeholders.last, let value = arguments[name] else {
        throw Unsupported(statement: statement)
      }
      return value
    }

    func integer() throws -> Int64 {
      // A client that sent the number as a string still means a number, and refusing that
      // would be pedantry about a value we can read.
      switch try value() {
      case .number(let number): return number
      case .text(let text):
        guard let number = Int64(text) else { throw Unsupported(statement: statement) }
        return number
      case .list: throw Unsupported(statement: statement)
      }
    }

    func string() throws -> String {
      guard case .text(let text) = try value() else { throw Unsupported(statement: statement) }
      return text
    }

    switch normalized {
    case "message.rowid > ?":
      return .rowIDGreaterThan(try integer())
    case "message.rowid <= ?":
      return .rowIDAtMost(try integer())
    case "message.is_from_me = ?":
      // 0/1 on the wire, because that is what the column holds and what the client sends.
      return .isFromMe(try integer() != 0)
    case "message.text like ? collate nocase", "message.text like ?":
      return .textLike(try string())
    case "message.guid in ( ? )":
      guard case .list(let guids) = try value() else { throw Unsupported(statement: statement) }
      return .guidIn(guids)
    case "message.associated_message_guid is null":
      return .notAssociated
    case "chat.guid = ?":
      return .chatGUID(try string())
    case "handle.id = ?":
      return .handleAddress(try string())
    default:
      throw Unsupported(statement: statement)
    }
  }
}
