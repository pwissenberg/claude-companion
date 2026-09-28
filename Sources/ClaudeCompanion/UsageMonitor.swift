import Foundation
import WebKit

/// Keeps track of how much of the Claude plan is left, by asking claude.ai the
/// same question its own usage page does.
///
/// The request is made from *inside* the web view rather than with URLSession.
/// The page is already signed in, same-origin, and past Cloudflare's checks - a
/// native request would have to copy cookies across and could still be
/// challenged. It runs in `.defaultClient`, an isolated script world, so it
/// cannot disturb or be disturbed by claude.ai's own JavaScript.
///
/// The account signed in to claude.ai can belong to several organizations - a
/// personal Max plan and a team, say - each with separate limits. Claude Code's
/// usage counts against the organization *it* is signed in to, so that one is
/// read from Claude Code's own config and preferred. Only if it isn't reachable
/// from this session does the monitor fall back to the web session's
/// subscription, and the menu names the plan, so it is always clear which is shown.
final class UsageMonitor {
    /// The most recent successful reading. Kept through transient failures, so a
    /// dropped request doesn't blank the menu bar.
    private(set) var usage: PlanUsage?
    /// Why the latest refresh failed, or nil if it succeeded.
    private(set) var problem: String?
    var onChange: (() -> Void)?

    /// Past this age a reading is shown dimmed: it may no longer be true.
    static let staleAfter: TimeInterval = 5 * 60

    private weak var webView: WKWebView?
    private var timer: Timer?
    private var inFlight = false
    private var loggedSummary = ""
    private let interval: TimeInterval = 60

    init(webView: WKWebView) {
        self.webView = webView
    }

    func start() {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 10
        // `.common`, so readings keep arriving while the menu is open - menu
        // tracking runs the loop in a mode the default one excludes.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var isStale: Bool {
        guard let usage else { return false }
        return Date().timeIntervalSince(usage.fetchedAt) > Self.staleAfter
    }

    func refresh() {
        guard !inFlight, let webView else { return }
        // Mid sign-in the main frame may be on another host, where the request
        // would go to the wrong origin. Still report in, so a reading that ages
        // past `staleAfter` meanwhile is redrawn dimmed.
        guard webView.url?.host == "claude.ai" else {
            onChange?()
            return
        }

        inFlight = true
        let preferred = Self.claudeCodeOrganization() ?? ""
        webView.callAsyncJavaScript(
            Self.fetchJS,
            arguments: ["preferred": preferred],
            in: nil,
            in: .defaultClient
        ) { [weak self] result in
            self?.inFlight = false
            self?.handle(result, preferred: preferred)
        }
    }

    private func handle(_ result: Result<Any, Error>, preferred: String) {
        switch result {
        case .failure(let error):
            fail("Couldn't reach claude.ai", log: error.localizedDescription)

        case .success(let value):
            guard let json = value as? String, let data = json.data(using: .utf8),
                  let fetched = try? UsageResponse.decode(data) else {
                fail("Unexpected response from claude.ai", log: "\(value)")
                return
            }
            if fetched.signedOut == true {
                // The previous reading belongs to a session that is gone, so
                // don't keep showing it.
                usage = nil
                fail("Sign in to Claude to see usage", log: "HTTP \(fetched.status)")
                return
            }
            guard let reading = PlanUsage(fetched, fetchedAt: Date()) else {
                fail("claude.ai reported no usage limits", log: "HTTP \(fetched.status): \(json.prefix(300))")
                return
            }

            let source = fetched.org?.uuid == preferred ? "Claude Code's organization"
                : "web session fallback"
            // Logged only when it changes. Compared as text rather than as values
            // because a rolling window's reset time shifts slightly between replies.
            let summary = "\(reading.plan) (\(source)) - " + reading.limits
                .map { "\($0.title) \(UsageText.percent($0.percentUsed)) used" }
                .joined(separator: ", ")
            if summary != loggedSummary || problem != nil {
                Log.info("usage: \(summary)")
                loggedSummary = summary
            }
            usage = reading
            problem = nil
            onChange?()
        }
    }

    private func fail(_ message: String, log detail: String) {
        if problem != message { Log.warn("usage: \(message) - \(detail)") }
        problem = message
        onChange?()
    }

    /// The organization Claude Code is signed in to, from `~/.claude.json` (or
    /// `$CLAUDE_CONFIG_DIR/.claude.json`). Re-read on every refresh, so signing
    /// Claude Code in to another account is picked up without a relaunch.
    static func claudeCodeOrganization() -> String? {
        let directory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let url = directory.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any] else { return nil }
        return account["organizationUuid"] as? String
    }

    /// Picks an organization and returns its usage, as a JSON string so the
    /// Swift side decodes it with `Codable` rather than picking through bridged
    /// dictionaries.
    ///
    /// Order of preference: Claude Code's organization; then one with a personal
    /// subscription; then the organization the web session last used; then any
    /// with chat.
    static let fetchJS = """
    const load = async (path) => {
      const response = await fetch('https://claude.ai/api/organizations' + path, {
        credentials: 'include', headers: { accept: 'application/json' }
      });
      return { status: response.status, body: response.ok ? await response.json() : null };
    };

    const orgs = await load('');
    if (!Array.isArray(orgs.body)) {
      return JSON.stringify({ status: orgs.status, signed_out: orgs.status === 401 || orgs.status === 403 });
    }

    const has = (org, capability) => (org.capabilities || []).includes(capability);
    const lastActive = (document.cookie.match(/(?:^|; )lastActiveOrg=([^;]+)/) || [])[1];
    const ranked = [
      ...orgs.body.filter(o => o.uuid === preferred),
      ...orgs.body.filter(o => has(o, 'claude_max') || has(o, 'claude_pro')),
      ...orgs.body.filter(o => o.uuid === lastActive),
      ...orgs.body.filter(o => has(o, 'chat')),
    ];

    // An organization can be listed yet have no plan usage to read - an API-only
    // one answers 403 - so fall through to the next candidate rather than stop.
    let status = 404;
    for (const org of ranked.filter((o, i) => ranked.indexOf(o) === i)) {
      const usage = await load('/' + org.uuid + '/usage');
      status = usage.status;
      if (!usage.body) continue;
      return JSON.stringify({
        status,
        org: {
          uuid: org.uuid, name: org.name,
          rate_limit_tier: org.rate_limit_tier, capabilities: org.capabilities
        },
        usage: usage.body
      });
    }
    return JSON.stringify({ status });
    """
}
