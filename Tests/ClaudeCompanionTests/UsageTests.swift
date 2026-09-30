import Foundation
import Testing
@testable import ClaudeCompanion

/// A real reply from claude.ai's usage endpoint (trimmed of the many null,
/// codenamed keys), wrapped the way `UsageMonitor.fetchJS` returns it.
private let maxPlanReply = #"""
{
  "status": 200,
  "org": {
    "uuid": "00000000-0000-0000-0000-000000000000",
    "name": "someone's Organization",
    "rate_limit_tier": "default_claude_max_20x",
    "capabilities": ["claude_max", "chat"]
  },
  "usage": {
    "five_hour": {"utilization": 13.0, "resets_at": "2026-09-28T14:19:59.612736+00:00"},
    "seven_day": {"utilization": 4.0, "resets_at": "2026-10-04T11:59:59.612758+00:00"},
    "seven_day_opus": null,
    "extra_usage": {"is_enabled": false, "monthly_limit": 2000, "utilization": 2.85},
    "limits": [
      {"kind": "session", "group": "session", "percent": 13, "severity": "normal",
       "resets_at": "2026-09-28T14:19:59.612736+00:00", "scope": null, "is_active": true},
      {"kind": "weekly_all", "group": "weekly", "percent": 4, "severity": "normal",
       "resets_at": "2026-10-04T11:59:59.612758+00:00", "scope": null, "is_active": false},
      {"kind": "weekly_scoped", "group": "weekly", "percent": 4, "severity": "normal",
       "resets_at": "2026-10-04T11:59:59.612929+00:00",
       "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
       "is_active": false}
    ]
  }
}
"""#

private func usage(from json: String) throws -> PlanUsage? {
    PlanUsage(try UsageResponse.decode(Data(json.utf8)), fetchedAt: Date())
}

private func limit(used: Double, severity: String? = "normal") -> UsageLimit {
    UsageLimit(title: "x", percentUsed: used, resetsAt: nil, isActive: false, severity: severity)
}

@Test func decodesEveryLimitFromARealReply() throws {
    let usage = try #require(try usage(from: maxPlanReply))

    #expect(usage.plan == "Max 20x")
    #expect(usage.limits.map(\.title) == [
        "Current session", "Weekly · all models", "Weekly · Fable",
    ])
    #expect(usage.limits.map(\.percentLeft) == [87, 96, 96])
    #expect(usage.limits[0].resetsAt == MaxResets.session)
}

@Test func headlineIsTheLimitClaudeMarksActive() throws {
    let usage = try #require(try usage(from: maxPlanReply))
    #expect(usage.headline?.title == "Current session")
}

@Test func headlineFallsBackToTheMostUsedLimit() {
    let usage = PlanUsage(
        plan: "Pro",
        limits: [
            UsageLimit(title: "session", percentUsed: 30, resetsAt: nil, isActive: false, severity: nil),
            UsageLimit(title: "weekly", percentUsed: 72, resetsAt: nil, isActive: false, severity: nil),
        ],
        fetchedAt: Date()
    )
    #expect(usage.headline?.title == "weekly")
}

@Test func fallsBackToPerWindowFieldsWithoutLimits() throws {
    let reply = #"""
    {"status": 200, "org": {"uuid": "o", "capabilities": ["claude_pro"]},
     "usage": {"five_hour": {"utilization": 40.0, "resets_at": "2026-09-28T10:20:00+00:00"},
               "seven_day": {"utilization": 72.0, "resets_at": null}}}
    """#
    let usage = try #require(try usage(from: reply))

    #expect(usage.plan == "Pro")
    #expect(usage.limits.map(\.title) == ["Current session", "Weekly · all models"])
    #expect(usage.headline?.percentLeft == 28)
}

@Test func noUsageMeansNoReading() throws {
    #expect(try usage(from: #"{"status": 403}"#) == nil)
    #expect(try usage(from: #"{"status": 200, "usage": {"limits": []}}"#) == nil)
}

@Test func refusedOrganizationListIsReported() throws {
    let result = try UsageResponse.decode(Data(#"{"status": 401, "refused": true}"#.utf8))
    #expect(result.refused == true)
}

@Test func limitsWithoutAPercentAreSkippedNotFatal() throws {
    let reply = #"""
    {"status": 200, "org": {"uuid": "o", "rate_limit_tier": "default_claude_max_20x"},
     "usage": {"limits": [
       {"kind": "session", "percent": 13, "severity": "normal", "is_active": true},
       {"kind": "weekly_opus", "percent": null, "severity": null},
       {"kind": "weekly_all", "severity": "normal"},
       {"percent": 40, "severity": "normal"}
     ]}}
    """#
    let usage = try #require(try usage(from: reply))

    #expect(usage.limits.map(\.title) == ["Current session", "Limit"])
    #expect(usage.limits.map(\.percentUsed) == [13, 40])
    #expect(usage.headline?.title == "Current session")
}

@Test func fallsBackToPerWindowFieldsWhenEveryLimitLacksAPercent() throws {
    let reply = #"""
    {"status": 200, "org": {"uuid": "o", "capabilities": ["claude_pro"]},
     "usage": {"five_hour": {"utilization": 40.0, "resets_at": null},
               "limits": [{"kind": "session", "percent": null}]}}
    """#
    let usage = try #require(try usage(from: reply))
    #expect(usage.limits.map(\.title) == ["Current session"])
    #expect(usage.headline?.percentLeft == 60)
}

@Test func percentagesOutsideTheRangeAreClamped() {
    #expect(limit(used: 130).percentLeft == 0)
    #expect(limit(used: 130).fractionLeft == 0)
}

@Test func levelsFollowWhatIsLeft() {
    #expect(limit(used: 50).level == .normal)
    #expect(limit(used: 75).level == .low)
    #expect(limit(used: 90).level == .critical)
    // claude.ai's own warning wins over our thresholds.
    #expect(limit(used: 50, severity: "warning").level == .low)
}

@Test func planNamesComeFromTheTier() {
    typealias Org = UsageFetchResult.Organization
    #expect(PlanUsage.planName(for: Org(uuid: "", name: "Team", rateLimitTier: "default_claude_max_5x", capabilities: [])) == "Max 5x")
    #expect(PlanUsage.planName(for: Org(uuid: "", name: "Acme", rateLimitTier: "default_raven", capabilities: ["raven", "chat"])) == "Acme")
    #expect(PlanUsage.planName(for: nil) == "Claude")
}

@Test func parsesMicrosecondAndWholeSecondTimestamps() {
    #expect(PlanUsage.parseDate("2026-09-28T14:19:59.612736+00:00") == MaxResets.session)
    #expect(PlanUsage.parseDate("2026-09-28T14:19:59+00:00") == MaxResets.session)
    #expect(PlanUsage.parseDate("not a date") == nil)
}

@Test func resetWording() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(UsageText.resets(at: nil, now: now) == "No reset scheduled")
    #expect(UsageText.resets(at: now.addingTimeInterval(-1), now: now) == "Reset pending")
    #expect(UsageText.resets(at: now.addingTimeInterval(-3 * 3600), now: now) == "Reset pending")
    #expect(UsageText.resets(at: now, now: now) == "Resets in under a minute")
    #expect(UsageText.resets(at: now.addingTimeInterval(30), now: now) == "Resets in under a minute")
    #expect(UsageText.resets(at: now.addingTimeInterval(28 * 60), now: now) == "Resets in 28 min")
    #expect(UsageText.resets(at: now.addingTimeInterval(4 * 3600), now: now) == "Resets in 4 hr")
    #expect(UsageText.resets(at: now.addingTimeInterval(4 * 3600 + 28 * 60 + 5), now: now)
        == "Resets in 4 hr 28 min")
    #expect(UsageText.resets(at: now.addingTimeInterval(3 * 86400), now: now).hasPrefix("Resets "))
}

@Test func distantResetsRoundToTheMinute() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    // A whole minute, so truncating the moment before it would give the minute before.
    let onTheMinute = Date(timeIntervalSince1970: 1_000_020 + 3 * 86400)
    #expect(UsageText.resets(at: onTheMinute.addingTimeInterval(-0.4), now: now)
        == UsageText.resets(at: onTheMinute, now: now))
}

@Test func updatedWording() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(UsageText.updated(at: now.addingTimeInterval(-20), now: now) == "Updated just now")
    #expect(UsageText.updated(at: now.addingTimeInterval(-60), now: now) == "Updated 1 min ago")
    #expect(UsageText.updated(at: now.addingTimeInterval(-12 * 60), now: now) == "Updated 12 min ago")
}

private enum MaxResets {
    /// 2026-09-28T14:19:59Z
    static let session = Date(timeIntervalSince1970: 1_790_605_199)
}
