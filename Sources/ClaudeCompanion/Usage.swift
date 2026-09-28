import Foundation

/// One plan limit - the current session or a weekly allowance - as claude.ai
/// reports it on its usage page.
struct UsageLimit: Equatable {
    enum Level: Equatable {
        case normal
        /// Running low: worth noticing before it becomes a problem.
        case low
        /// Nearly or entirely used up.
        case critical
    }

    let title: String
    /// Share of the allowance already used, 0...100.
    let percentUsed: Double
    let resetsAt: Date?
    /// Whether claude.ai marks this as the limit currently constraining you.
    let isActive: Bool
    /// claude.ai's own verdict (`normal` while there is plenty left).
    let severity: String?

    var percentLeft: Double { max(0, 100 - percentUsed) }
    var fractionLeft: Double { percentLeft / 100 }

    /// Thresholds are ours, but any severity claude.ai raises beyond `normal`
    /// counts too, so a warning it shows on the web is never shown here as fine.
    var level: Level {
        if percentLeft <= 10 { return .critical }
        if percentLeft <= 25 { return .low }
        if let severity, severity != "normal" { return .low }
        return .normal
    }
}

/// A snapshot of every limit on one plan.
struct PlanUsage: Equatable {
    /// "Max 20x", "Pro", or the organization's name when the tier is unknown.
    let plan: String
    let limits: [UsageLimit]
    let fetchedAt: Date

    /// The limit you will run into first: the one claude.ai marks active, or
    /// failing that the most used. This is what the menu bar shows.
    var headline: UsageLimit? {
        limits.first(where: \.isActive) ?? limits.max { $0.percentUsed < $1.percentUsed }
    }
}

// MARK: - Decoding

/// What `UsageMonitor.fetchJS` returns: the organization it chose, and that
/// organization's `/usage` response verbatim.
struct UsageFetchResult: Decodable {
    struct Organization: Decodable {
        let uuid: String
        let name: String?
        let rateLimitTier: String?
        let capabilities: [String]?
    }

    /// HTTP status of the last request made - the organization list if that
    /// failed, otherwise the usage request.
    let status: Int
    /// Set when the organization list itself was refused: nobody is signed in.
    let signedOut: Bool?
    let org: Organization?
    let usage: UsageResponse?
}

/// The parts of `GET /api/organizations/<uuid>/usage` the app uses.
///
/// `limits` is the normalised list claude.ai's own usage page renders from. The
/// older per-window fields (`five_hour`, `seven_day`) are kept as a fallback in
/// case `limits` is ever missing - the response carries a lot of experimental,
/// codenamed keys, so neither shape can be assumed to be permanent.
struct UsageResponse: Decodable {
    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { let displayName: String? }
            let model: Model?
        }

        let kind: String
        let group: String?
        let percent: Double
        let severity: String?
        let resetsAt: String?
        let scope: Scope?
        let isActive: Bool?
    }

    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
    }

    let limits: [Limit]?
    let fiveHour: Window?
    let sevenDay: Window?

    static func decode(_ data: Data) throws -> UsageFetchResult {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UsageFetchResult.self, from: data)
    }
}

extension PlanUsage {
    init?(_ result: UsageFetchResult, fetchedAt: Date) {
        guard let usage = result.usage else { return nil }

        var limits = (usage.limits ?? []).map { limit in
            UsageLimit(
                title: Self.title(for: limit),
                percentUsed: min(max(limit.percent, 0), 100),
                resetsAt: limit.resetsAt.flatMap(Self.parseDate),
                isActive: limit.isActive ?? false,
                severity: limit.severity
            )
        }
        if limits.isEmpty {
            let windows = [("Current session", usage.fiveHour), ("Weekly · all models", usage.sevenDay)]
            limits = windows.compactMap { title, window in
                guard let used = window?.utilization else { return nil }
                return UsageLimit(
                    title: title,
                    percentUsed: min(max(used, 0), 100),
                    resetsAt: window?.resetsAt.flatMap(Self.parseDate),
                    isActive: false,
                    severity: nil
                )
            }
        }
        guard !limits.isEmpty else { return nil }

        self.init(plan: Self.planName(for: result.org), limits: limits, fetchedAt: fetchedAt)
    }

    private static func title(for limit: UsageResponse.Limit) -> String {
        switch limit.kind {
        case "session":
            return "Current session"
        case "weekly_all":
            return "Weekly · all models"
        case "weekly_scoped":
            return "Weekly · " + (limit.scope?.model?.displayName ?? "scoped")
        default:
            // An unrecognised kind is still worth showing; its own name is the
            // most honest label available.
            return limit.kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func planName(for org: UsageFetchResult.Organization?) -> String {
        let tier = org?.rateLimitTier ?? ""
        let capabilities = org?.capabilities ?? []
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        if capabilities.contains("claude_max") { return "Max" }
        if capabilities.contains("claude_pro") { return "Pro" }
        return org?.name ?? "Claude"
    }

    /// claude.ai mixes microsecond timestamps (`2026-09-28T14:19:59.612736+00:00`)
    /// with whole-second ones (`2026-10-02T06:59:59+00:00`) in the same reply, and
    /// `ISO8601DateFormatter` parses one form or the other, never both. Sub-second
    /// precision is irrelevant for a reset time, so the fraction is dropped and
    /// every stamp parsed as whole seconds.
    static func parseDate(_ string: String) -> Date? {
        let whole = string.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression
        )
        return ISO8601DateFormatter().date(from: whole)
    }
}

// MARK: - Wording

enum UsageText {
    /// "Resets in 4 hr 28 min" within a day - the wording claude.ai's usage page
    /// uses - and a weekday and time beyond that, where a countdown in hours stops
    /// being easy to picture.
    static func resets(at date: Date?, now: Date = Date()) -> String {
        guard let date else { return "No reset scheduled" }
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 { return "Resets in under a minute" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return "Resets in \(minutes) min" }
        if minutes < 24 * 60 {
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? "Resets in \(hours) hr" : "Resets in \(hours) hr \(rest) min"
        }

        // Rounded to the minute: resets land a hair before the hour (13:59:59.6),
        // which a formatter would truncate to a time that looks arbitrary.
        let rounded = Date(timeIntervalSinceReferenceDate:
            (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
        return "Resets " + formatter.string(from: rounded)
    }

    static func updated(at date: Date, now: Date = Date()) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "Updated just now"
        case 1: return "Updated 1 min ago"
        case ..<60: return "Updated \(minutes) min ago"
        default:
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("jmm")
            return "Updated at " + formatter.string(from: date)
        }
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}
