//  ConnectionMethodToolTests
//  A connection method that needs a binary says so, and says which one.
//
//  Without this, choosing ngrok looks complete: the picker shows ngrok, no field is blank,
//  and the tunnel then fails to start with the reason only in the log. A binary that has not
//  been downloaded is a required thing that is missing, exactly like an empty auth token —
//  the row needs a way to know about it.
//
//  What is asserted is the DECLARATION the row reads, not the SwiftUI. The row derives
//  everything from `manifest.tools`, so a third-party connection method gets the warning and
//  the download button without that file learning its name — and that only holds while the
//  tool-backed methods actually declare their tool.

import BBServiceKit
import Testing

@testable import BBBuiltIns
@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Connection methods declare the binaries they need")
struct ConnectionMethodToolTests {

  private var connectionMethods: [ServiceManifest] {
    BuiltInManifests.all.filter { $0.category == .reverseProxy }
  }

  @Test("Every tunnel that runs a binary declares it")
  func tunnelsDeclareTheirTool() throws {
    // Named individually rather than "every method with a process", because the point is
    // that these three specifically must not silently lose their declaration.
    for id in [
      "app.bluebubbles.proxy.ngrok", "app.bluebubbles.proxy.cloudflare",
      "app.bluebubbles.proxy.zrok",
    ] {
      let manifest = try #require(connectionMethods.first { $0.id.rawValue == id })
      #expect(!manifest.tools.isEmpty, "\(manifest.name) declares no tool")
    }
  }

  @Test("Methods that need no binary declare none")
  func localMethodsDeclareNoTool() throws {
    // The other half. If Local Network declared a tool, the row would warn about a download
    // that is never coming and offer a button that cannot succeed.
    for id in ["app.bluebubbles.proxy.lan", "app.bluebubbles.proxy.dynamic-dns"] {
      let manifest = try #require(connectionMethods.first { $0.id.rawValue == id })
      #expect(manifest.tools.isEmpty, "\(manifest.name) declares a tool it does not need")
    }
  }

  @Test("Every declared tool is nameable in a sentence")
  func toolsAreNameable() {
    // The warning and the button both interpolate `displayName`; an empty one produces
    // "needs the  binary" and a button labelled "Download".
    for manifest in connectionMethods {
      for tool in manifest.tools {
        #expect(!tool.displayName.isEmpty, "\(manifest.name)'s tool has no display name")
        #expect(!tool.id.isEmpty, "\(manifest.name)'s tool has no id")
      }
    }
  }

  @Test("A method needs at most one tool, which is what the row shows")
  func atMostOneTool() {
    // The row reads `tools.first`. A method declaring two would warn about one and silently
    // ignore the other, so this is the assumption written down rather than left implicit.
    for manifest in connectionMethods {
      #expect(manifest.tools.count <= 1, "\(manifest.name) declares \(manifest.tools.count) tools")
    }
  }
}
