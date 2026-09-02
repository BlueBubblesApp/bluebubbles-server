//  LANAddressOptionsTests
//  The Local Network address field offers this machine's actual interfaces.
//
//  It was a free-text box whose own manifest comment described the select it was supposed to
//  be. Typing an address by hand is the worst version of this choice: the value only works
//  if it exactly matches an address the Mac currently holds, and getting it wrong publishes
//  an address no client can reach — with the failure appearing on the client, later.

import BBServiceKit
import BBSystem
import Testing

@testable import BBBuiltIns
@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Local Network address options")
struct LANAddressOptionsTests {

  private var addressField: FieldDescriptor? {
    for entry in BuiltInManifests.lan.settings {
      if case .field(let descriptor) = entry, descriptor.key == "address" { return descriptor }
    }
    return nil
  }

  @Test("The address field is a select, not free text")
  func fieldIsASelect() throws {
    let field = try #require(addressField)
    guard case .select = field.kind else {
      Issue.record("address is \(field.kind), not a select")
      return
    }
  }

  @Test("Automatic is offered first, and empty means automatic")
  func automaticIsFirstAndEmpty() throws {
    let field = try #require(addressField)
    guard case .select(let options) = field.kind else { return }
    let first = try #require(options.first)
    // Empty is the value `ProxyService<LANMethod>` already treats as "pick for me". The option has
    // to carry that exact value or choosing Automatic would pin a literal string.
    #expect(first.value.isEmpty)
    #expect(first.label.hasPrefix("Automatic"))
  }

  @Test("Every interface on this machine is offered")
  func interfacesAreOffered() throws {
    let field = try #require(addressField)
    guard case .select(let options) = field.kind else { return }
    let offered = Set(options.map(\.value))
    for address in SystemInfo.localAddresses(.ipv4) {
      #expect(offered.contains(address), "\(address) is not offered")
    }
  }

  @Test("Options are distinct, so the picker cannot show duplicates")
  func optionsAreDistinct() throws {
    let field = try #require(addressField)
    guard case .select(let options) = field.kind else { return }
    // The form's `ForEach` is keyed by `value`; duplicates would collapse rows or render
    // unpredictably.
    #expect(Set(options.map(\.value)).count == options.count)
  }

  @Test("Every option is labelled")
  func optionsAreLabelled() throws {
    let field = try #require(addressField)
    guard case .select(let options) = field.kind else { return }
    for option in options {
      #expect(!option.label.isEmpty, "unlabelled option for \(option.value)")
    }
  }
}
