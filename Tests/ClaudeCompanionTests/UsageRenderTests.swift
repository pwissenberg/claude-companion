import AppKit
import Foundation
import Testing
@testable import ClaudeCompanion

/// The usage display is drawn by Control Center, out of process, so it cannot be
/// captured from the app. These tests draw the same views offscreen instead and,
/// when `CLAUDE_COMPANION_RENDER_DIR` is set, write them out as PNGs to look at.
///
/// On the main actor: AppKit views and Auto Layout must be touched from the main
/// thread, and Swift Testing otherwise runs tests wherever it likes.
private let renderDirectory = ProcessInfo.processInfo.environment["CLAUDE_COMPANION_RENDER_DIR"]
    .map { URL(fileURLWithPath: $0) }

private func write(_ image: NSImage, as name: String) throws {
    guard let directory = renderDirectory else { return }
    let tiff = try #require(image.tiffRepresentation)
    let rep = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try png.write(to: directory.appendingPathComponent(name))
}

private func limit(_ title: String, used: Double, resetsIn: TimeInterval?, active: Bool = false,
                   severity: String? = "normal", now: Date) -> UsageLimit {
    UsageLimit(
        title: title, percentUsed: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) },
        isActive: active, severity: severity
    )
}

@Test @MainActor func statusImageIsATemplateWithRoomForSymbolAndRing() {
    let image = UsageIndicator.statusImage(fractionLeft: 0.87, dimmed: false)
    #expect(image.isTemplate)
    #expect(image.size.width > image.size.height)
    #expect(image.size.height >= 13)
}

@Test @MainActor func statusTitleShowsWhatIsLeftInTheLevelColour() {
    let now = Date()
    let fine = UsageIndicator.statusTitle(for: limit("s", used: 13, resetsIn: 3600, now: now), dimmed: false)
    let low = UsageIndicator.statusTitle(for: limit("s", used: 80, resetsIn: 3600, now: now), dimmed: false)
    let critical = UsageIndicator.statusTitle(for: limit("s", used: 95, resetsIn: 3600, now: now), dimmed: false)
    let stale = UsageIndicator.statusTitle(for: limit("s", used: 13, resetsIn: 3600, now: now), dimmed: true)

    #expect(fine.string == "87%")
    #expect(low.string == "20%")
    #expect(critical.string == "5%")
    #expect(fine.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
    #expect(low.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemOrange)
    #expect(critical.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemRed)
    #expect(stale.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
}

@Test @MainActor func menuRowDescribesTheLimitForAccessibility() {
    let now = Date()
    let row = UsageRowView(limit: limit("Current session", used: 13, resetsIn: 4 * 3600 + 28 * 60, active: true, now: now), now: now)
    #expect(row.accessibilityLabel() == "Current session: 87% left. Resets in 4 hr 28 min")

    let spent = UsageRowView(limit: limit("Weekly · all models", used: 100, resetsIn: -60, now: now), now: now)
    #expect(spent.accessibilityLabel() == "Weekly · all models: 0% left. Reset pending")
}

@Test @MainActor func previewRendersEveryLevelInLightAndDark() throws {
    let now = Date()
    let usage = PlanUsage(
        plan: "Max 20x",
        limits: [
            limit("Current session", used: 13, resetsIn: 4 * 3600 + 28 * 60, active: true, now: now),
            limit("Weekly · all models", used: 4, resetsIn: 3 * 86400 + 7200, now: now),
            limit("Weekly · Fable", used: 4, resetsIn: 3 * 86400 + 7200, now: now),
        ],
        fetchedAt: now
    )
    let image = try #require(UsageIndicator.preview(of: usage, stale: false))
    #expect(image.size.width >= UsageRowView.width)
    // Five menu-bar variants and three rows, twice over: nothing collapsed to zero.
    #expect(image.size.height >= 2 * (5 * 24 + 3 * 50))
    try write(image, as: "usage-preview.png")
}

@Test @MainActor func previewShowsAWarningLevelHeadlineAndPendingReset() throws {
    let now = Date()
    let usage = PlanUsage(
        plan: "Pro",
        limits: [
            limit("Current session", used: 92, resetsIn: 12 * 60, active: true, severity: "warning", now: now),
            limit("Weekly · all models", used: 78, resetsIn: -30, now: now),
        ],
        fetchedAt: now.addingTimeInterval(-UsageMonitor.staleAfter - 1)
    )
    let image = try #require(UsageIndicator.preview(of: usage, stale: true))
    #expect(image.size.height >= 2 * (5 * 24 + 2 * 50))
    try write(image, as: "usage-preview-low.png")
}
