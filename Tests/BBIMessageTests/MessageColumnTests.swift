//  MessageColumnTests
//  The message SELECT asks for exactly the columns `IMessageRow` maps.
//
//  Both directions fail differently and both are silent. A column selected and never mapped
//  costs every message read its bytes and a slot in the column index, and nothing on the wire
//  changes when it goes. A column mapped and never selected reads as absent on every schema,
//  so the serializer omits a key that the database has, which is a v1 break nobody sees in a
//  diff of the SQL.
//
//  The mapping is read from the source because `MappedRow` answers nil for a column the
//  statement did not carry, by design (an older schema lacks some), so no runtime check can
//  tell "absent from this macOS" from "never asked for".

import BBTestSupport
import Foundation
import Testing

@testable import BBIMessage

@Suite("Message columns")
struct MessageColumnTests {

  /// Every column name `IMessageRow.init(_:dateUnit:)` reads, from its body.
  private func mappedColumns() throws -> Set<String> {
    let code = try SourceScanner.file("Sources/BBIMessage/Rows.swift").code
    let type = try #require(code.range(of: "public struct IMessageRow"))
    let initialiser = try #require(
      code.range(of: "init(_ r: MappedRow, dateUnit:", range: type.upperBound..<code.endIndex))
    // The body ends at the first line that closes at the struct's member indentation.
    let end = try #require(
      code.range(of: "\n  }\n", range: initialiser.upperBound..<code.endIndex))
    let body = code[initialiser.upperBound..<end.lowerBound]

    let read = try Regex(#"r\.(?:required|optional|bool|boolIfPresent)\("([A-Za-z_]+)"\)"#)
    return Set(body.matches(of: read).compactMap { $0.output[1].substring.map(String.init) })
  }

  @Test("Every selected column is mapped, and every mapped column is selected")
  func selectionMatchesTheMapping() throws {
    let mapped = try mappedColumns()
    // Non-vacuity: a regex that matched nothing would make both checks below pass.
    #expect(mapped.count > 40, "only \(mapped.count) mapped columns found; the scan is broken")

    let selected = Set(MessageRepository.messageColumns)
    #expect(
      selected.subtracting(mapped).isEmpty,
      "selected and never mapped: \(selected.subtracting(mapped).sorted())")
    #expect(
      mapped.subtracting(selected).isEmpty,
      "mapped and never selected, so always absent: \(mapped.subtracting(selected).sorted())")
    #expect(selected.count == MessageRepository.messageColumns.count, "a column is listed twice")
  }
}
