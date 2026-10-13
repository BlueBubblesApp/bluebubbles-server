//  DaemonLedgerPolicyTests
//  No code reaches the daemon ledger except the one the composition root built.
//
//  The ledger is a file the next server start reads and SIGTERMs every pid in. A
//  process-wide default for it named the real installation's file, so anything that said
//  nothing (a tunnel factory, a test) recorded into the list a real server reaps from. The
//  root builds one per server and passes it down; this scan keeps a default from coming back.

import BBTestSupport
import Testing

@Suite("The daemon ledger is injected")
struct DaemonLedgerPolicyTests {

  @Test("Nothing declares or reaches a process-wide daemon ledger")
  func noSharedLedger() throws {
    let pattern = try Regex(#"DaemonLedger\.shared|ledger:\s*\.shared"#)
    let declaration = try Regex(#"static\s+(let|var)\s+shared\b"#)
    // This file spells the shapes it refuses.
    let files = try SourceScanner.swiftFiles(under: "Sources", "Tests", minimum: 1000)
      .filter { $0.name != "DaemonLedgerPolicyTests.swift" }
    let offences = SourceScanner.offences(in: files) { file, line in
      line.code.contains(pattern)
        || (file.name == "DaemonLedger.swift" && line.code.contains(declaration))
    }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "a daemon ledger is reached as a default; pass the one the caller was given:\n"
          + offences.report))
  }

  /// The installation's ledger file is named in exactly one place.
  @Test("Only the composition root builds a ledger on the support directory")
  func onlyTheRootNamesTheRealFile() throws {
    let files = try SourceScanner.swiftFiles(under: "Sources", minimum: 500)
    // The root is one type split across extension files, so the exemption is the family.
    let root = Set(
      try SourceScanner.family(
        "Sources/BlueBubblesServerCore/Composition/ServerComposition.swift"
      ).map(\.path))
    let offences = SourceScanner.offences(in: files) { file, line in
      line.code.contains("\"daemons.json\"") && !root.contains(file.path)
    }
    #expect(
      offences.isEmpty,
      Comment(rawValue: "the ledger file is named outside the root:\n" + offences.report))
  }
}
