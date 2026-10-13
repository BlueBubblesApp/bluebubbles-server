//  AuditRetentionTests
//  How long a record is kept, and what the stored field means.

import Foundation
import Testing

@testable import BBAudit

@Suite("Audit retention")
struct AuditRetentionTests {

  @Test("An unset or unreadable field is the ninety-day default")
  func defaults() {
    #expect(AuditRetentionPolicy.parse(nil).days == 90)
    #expect(AuditRetentionPolicy.parse("").days == 90)
    #expect(AuditRetentionPolicy.parse("forever").days == 90)
    #expect(AuditRetentionPolicy.parse(" 30 ").days == 30)
  }

  @Test("Zero keeps everything and never produces a cutoff")
  func zeroIsForever() {
    let policy = AuditRetentionPolicy(days: 0)
    #expect(policy.keepsForever)
    #expect(policy.cutoff(now: Date()) == nil)
    #expect(policy.summary == "kept forever")
  }

  @Test("The cutoff is exactly the day count back from now")
  func cutoff() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let cutoff = AuditRetentionPolicy(days: 7).cutoff(now: now)
    #expect(cutoff == now.addingTimeInterval(-7 * 24 * 60 * 60))
    #expect(AuditRetentionPolicy(days: 7).summary == "kept for 7 days")
  }

  @Test("Days are clamped to the field's range")
  func clamping() {
    #expect(AuditRetentionPolicy(days: -5).days == 0)
    #expect(AuditRetentionPolicy(days: 99_999).days == AuditRetentionPolicy.maximumDays)
    #expect(AuditRetentionPolicy.parse("-1").keepsForever)
  }

  @Test("The sweep is daily")
  func sweepInterval() {
    #expect(AuditRetentionPolicy.sweepInterval == .seconds(86_400))
  }
}
