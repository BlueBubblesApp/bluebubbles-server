//  AlertReporterTests
//  The one bridge from a module's "tell the user" to the alert centre.

import BBCore
import BBDiagnostics
import Foundation
import Testing

@Suite("Alert reporter")
struct AlertReporterTests {

  @Test("A report becomes an alert filed under the module's source")
  func filesUnderSource() async {
    let center = AlertCenter()
    let reporter = AlertCenterReporter(center: center, source: "Push", severity: .warning)

    await reporter.raise(title: "Rules repaired", detail: "They were world-writable.")

    let alerts = await center.all()
    #expect(alerts.count == 1)
    #expect(alerts.first?.source == "Push")
    #expect(alerts.first?.severity == .warning)
    #expect(alerts.first?.title == "Rules repaired")
    #expect(alerts.first?.body == "They were world-writable.")
  }

  @Test("A dedupe key coalesces a retry loop into one row")
  func dedupeCoalesces() async {
    let center = AlertCenter()
    let reporter = AlertCenterReporter(
      center: center, source: "PrivateAPI", dedupeKey: "private-api.injection"
    )

    await reporter.raise(title: "Injection failed", detail: "attempt 1")
    await reporter.raise(title: "Injection failed", detail: "attempt 2")

    let alerts = await center.all()
    #expect(alerts.count == 1)
    #expect(alerts.first?.occurrenceCount == 2)
  }

  @Test("Without a key, distinct events stay distinct")
  func noKeyNoCoalescing() async {
    let center = AlertCenter()
    let reporter = AlertCenterReporter(center: center, source: "Push")
    await reporter.raise(title: "One", detail: "")
    await reporter.raise(title: "Two", detail: "")
    #expect(await center.all().count == 2)
  }
}
