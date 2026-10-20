import Foundation
import WebKit

/// Holds live column `WKWebView` refs for the opt-in agent bridge.
@MainActor
final class ColumnRegistry {
    static let shared = ColumnRegistry()

    struct ColumnSnapshot: Sendable {
        let index: Int
        let type: String
        let url: String?
        let isLoading: Bool
        let hasWebView: Bool
        /// N3: mid-load / waiting for first cards.
        let hydrating: Bool
        /// N3: past grace, still empty after one self-heal reload (or heal exhausted).
        let stale: Bool
    }

    private struct Entry {
        var type: String
        weak var webView: WKWebView?
        var url: URL?
        var isLoading: Bool
        /// When the latest navigation finished (`isLoading` → false).
        var loadFinishedAt: Date?
        /// True after one automatic reload for blank post-load columns.
        var hydrateHealAttempted: Bool = false
        /// Last observed card count (tweets or notification cells).
        var lastCardCount: Int = 0
        /// Scheduled self-heal task for this column (cancelled on new load).
        var hydrateTask: Task<Void, Never>?
    }

    private var entries: [Int: Entry] = [:]
    /// WebViews whose location is owned by agent `navigate` — ignore SwiftUI URL binding loads.
    private var ignoreBindingLoad: Set<ObjectIdentifier> = []
    /// Best-effort logged-in handle scraped from the profile column / login flow.
    var userHandle: String?

    /// Seconds after load with zero cards before one automatic reload (N3).
    private static let hydrateGraceSeconds: TimeInterval = 5.0

    private init() {}

    struct NavigateResult: Sendable {
        let ok: Bool
        let column: Int
        let url: String
        let finalURL: String
        let method: String
        let ready: Bool
        let tweetCount: Int
        let errorShell: Bool
        let challenge: Bool
        let retries: Int
        let waitedMs: Int
        /// Status pages only: true when root + ≥1 reply/card visible after settle/scroll.
        /// False when only the root tweet rendered (common if WebView was occluded/hidden).
        let repliesLoaded: Bool?
        /// N4: X status URL resolved to the not-found page (fail-fast, no retries).
        let notFound: Bool
    }

    func shouldIgnoreBindingLoad(_ webView: WKWebView) -> Bool {
        ignoreBindingLoad.contains(ObjectIdentifier(webView))
    }

    func clearIgnoreBindingLoad(_ webView: WKWebView) {
        ignoreBindingLoad.remove(ObjectIdentifier(webView))
    }

    private func markIgnoreBindingLoad(_ webView: WKWebView) {
        ignoreBindingLoad.insert(ObjectIdentifier(webView))
    }

    func register(index: Int, type: String, webView: WKWebView, url: URL?, isLoading: Bool) {
        entries[index]?.hydrateTask?.cancel()
        entries[index] = Entry(
            type: type,
            webView: webView,
            url: url,
            isLoading: isLoading,
            loadFinishedAt: isLoading ? nil : Date(),
            hydrateHealAttempted: false,
            lastCardCount: 0,
            hydrateTask: nil
        )
        if !isLoading {
            scheduleHydrateWatch(index: index)
        }
    }

    func update(index: Int, url: URL?, isLoading: Bool?) {
        guard var entry = entries[index] else { return }
        if let url { entry.url = url }
        if let isLoading {
            let wasLoading = entry.isLoading
            entry.isLoading = isLoading
            if isLoading && !wasLoading {
                // New navigation started — cancel pending watch; keep hydrateHealAttempted
                // so self-heal reload cannot loop forever (reset only via navigate / manual reload).
                entry.loadFinishedAt = nil
                entry.lastCardCount = 0
                entry.hydrateTask?.cancel()
                entry.hydrateTask = nil
            } else if !isLoading && wasLoading {
                entry.loadFinishedAt = Date()
                entries[index] = entry
                scheduleHydrateWatch(index: index)
                return
            }
        }
        entries[index] = entry
    }

    func unregister(index: Int, webView: WKWebView) {
        guard let entry = entries[index], entry.webView === webView else { return }
        entry.hydrateTask?.cancel()
        entries.removeValue(forKey: index)
    }

    func snapshot() -> [ColumnSnapshot] {
        entries.keys.sorted().compactMap { index in
            guard let entry = entries[index] else { return nil }
            let flags = hydrateFlags(for: entry)
            return ColumnSnapshot(
                index: index,
                type: entry.type,
                url: entry.url?.absoluteString,
                isLoading: entry.isLoading,
                hasWebView: entry.webView != nil,
                hydrating: flags.hydrating,
                stale: flags.stale
            )
        }
    }

    /// N3 flags for a single column (also used by read_column).
    func hydrateFlags(forColumn index: Int) -> (hydrating: Bool, stale: Bool) {
        guard let entry = entries[index] else { return (false, false) }
        return hydrateFlags(for: entry)
    }

    private func hydrateFlags(for entry: Entry) -> (hydrating: Bool, stale: Bool) {
        if entry.isLoading {
            return (true, false)
        }
        if entry.lastCardCount > 0 {
            return (false, false)
        }
        guard let finished = entry.loadFinishedAt else {
            // Registered but never finished a load yet.
            return (true, false)
        }
        let elapsed = Date().timeIntervalSince(finished)
        if elapsed < Self.hydrateGraceSeconds {
            return (true, false)
        }
        // Past grace, still empty.
        if entry.hydrateHealAttempted {
            return (false, true)
        }
        // Grace elapsed but heal not yet run / in flight.
        return (true, false)
    }

    /// N3: if still no cards after grace, reload once.
    private func scheduleHydrateWatch(index: Int) {
        entries[index]?.hydrateTask?.cancel()
        let graceNs = UInt64(Self.hydrateGraceSeconds * 1_000_000_000)
        entries[index]?.hydrateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: graceNs)
            guard let self, !Task.isCancelled else { return }
            await self.maybeSelfHealHydrate(index: index)
        }
    }

    private func maybeSelfHealHydrate(index: Int) async {
        guard var entry = entries[index], entry.webView != nil else { return }
        if entry.isLoading || entry.hydrateHealAttempted { return }
        guard entry.loadFinishedAt != nil else { return }
        let cards = await cardCount(column: index)
        entry.lastCardCount = cards
        entries[index] = entry
        if cards > 0 { return }
        entry.hydrateHealAttempted = true
        entries[index] = entry
        print("[AgentBridge] hydrate self-heal reload column=\(index) (0 cards after \(Int(Self.hydrateGraceSeconds))s)")
        do {
            try reload(column: index, resetHydrateHeal: false)
        } catch {
            print("[AgentBridge] hydrate self-heal failed column=\(index): \(error.localizedDescription)")
        }
    }

    /// Tweet cards, or notification cells when on /notifications.
    private func cardCount(column index: Int) async -> Int {
        let js = #"""
        (function() {
          var tweets = document.querySelectorAll('article[data-testid="tweet"]').length;
          var path = String(location.pathname || '');
          if (/\/notifications/i.test(path)) {
            var cells = document.querySelectorAll('[data-testid="cellInnerDiv"]').length;
            return Math.max(tweets, cells);
          }
          return tweets;
        })()
        """#
        do {
            let raw = try await evaluateJavaScript(column: index, script: js)
            if let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return n
            }
            if let data = raw.data(using: .utf8),
               let num = try? JSONSerialization.jsonObject(with: data) as? NSNumber {
                return num.intValue
            }
        } catch {}
        return 0
    }

    /// Refresh lastCardCount (call from read/health so flags stay honest).
    func refreshCardCount(column index: Int) async {
        guard entries[index] != nil else { return }
        let cards = await cardCount(column: index)
        entries[index]?.lastCardCount = cards
    }

    func webView(at index: Int) -> WKWebView? {
        entries[index]?.webView
    }

    func columnCount() -> Int {
        entries.count
    }

    /// Evaluate JavaScript in a column WebView and return a JSON-friendly string result.
    func evaluateJavaScript(column index: Int, script: String) async throws -> String {
        guard let webView = entries[index]?.webView else {
            throw AgentBridgeError.columnNotFound(index)
        }
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: AgentBridgeError.jsError(error.localizedDescription))
                    return
                }
                continuation.resume(returning: Self.stringifyJSResult(result))
            }
        }
    }

    /// Load a URL in the column WebView (e.g. `https://x.com/search?q=…`).
    /// Search URLs: prefer in-SPA SearchBox submit; wait for tweets / empty / error; retry hard load.
    func navigate(column index: Int, to url: URL) async throws -> NavigateResult {
        guard let webView = entries[index]?.webView else {
            throw AgentBridgeError.columnNotFound(index)
        }
        markIgnoreBindingLoad(webView)
        let cleanURL = Self.stripFailedScript(url)
        entries[index]?.hydrateTask?.cancel()
        entries[index]?.url = cleanURL
        entries[index]?.isLoading = true
        entries[index]?.loadFinishedAt = nil
        entries[index]?.hydrateHealAttempted = false
        entries[index]?.lastCardCount = 0

        let started = Date()
        var method = "assign"
        var retries = 0
        let isSearch = cleanURL.path.lowercased().contains("/search")
        let isStatus = cleanURL.path.range(of: "/status/", options: .caseInsensitive) != nil
        let settleTimeoutMs = (isSearch || isStatus) ? 16_000 : 10_000
        let sameSite = Self.isSameXSite(webView.url, cleanURL)

        // If the column is already an error shell, recover to a warm home first.
        var probe = await pageProbe(column: index)
        if probe.errorShell || probe.challenge {
            method = "recover-home"
            try await hardLoad(webView: webView, url: URL(string: "https://x.com/home")!)
            probe = await waitForPage(column: index, timeoutMs: 12_000, acceptSearchEmpty: false)
            if probe.errorShell {
                _ = try? await evaluateJavaScript(column: index, script: AgentDOM.clickTryAgainJS)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                try await hardLoad(webView: webView, url: URL(string: "https://x.com/home")!)
                probe = await waitForPage(column: index, timeoutMs: 12_000, acceptSearchEmpty: false)
                retries += 1
            }
        }

        let healthy = probe.ready && !probe.errorShell
        if sameSite && healthy {
            // Prefer pushState SPA routing — full assign/load often yields failedScript shells.
            let softNav = await attemptSoftNavigate(column: index, url: cleanURL)
            if softNav.ok {
                method = softNav.method
            } else if isSearch {
                let softSearch = await attemptSoftSearch(column: index, url: cleanURL, healthy: true)
                if softSearch.ok {
                    method = softSearch.method
                } else if softSearch.method == "opened_explore" {
                    _ = await waitForPage(column: index, timeoutMs: 8_000, acceptSearchEmpty: false)
                    let again = await attemptSoftNavigate(column: index, url: cleanURL)
                    if again.ok {
                        method = "explore+pushstate"
                    } else {
                        let box = await attemptSoftSearch(column: index, url: cleanURL, healthy: true)
                        method = box.ok ? box.method : "assign"
                        if !box.ok { try await locationAssign(column: index, url: cleanURL) }
                    }
                } else {
                    method = "assign"
                    try await locationAssign(column: index, url: cleanURL)
                }
            } else {
                method = "assign"
                try await locationAssign(column: index, url: cleanURL)
            }
        } else if isSearch {
            // Unhealthy column: hard-load home, then pushState to search.
            method = "recover+pushstate"
            try await hardLoad(webView: webView, url: URL(string: "https://x.com/home")!)
            probe = await waitForPage(column: index, timeoutMs: 12_000, acceptSearchEmpty: false)
            if probe.ready && !probe.errorShell {
                let softNav = await attemptSoftNavigate(column: index, url: cleanURL)
                method = softNav.ok ? softNav.method : "load"
                if !softNav.ok { try await hardLoad(webView: webView, url: cleanURL) }
            } else {
                method = "load"
                try await hardLoad(webView: webView, url: cleanURL)
            }
        } else {
            method = "load"
            try await hardLoad(webView: webView, url: cleanURL)
        }

        // N4: shorter first settle for status — not-found pages should surface quickly.
        let firstSettleMs = isStatus ? min(settleTimeoutMs, 8_000) : settleTimeoutMs
        var finalProbe = await waitForPage(
            column: index,
            timeoutMs: firstSettleMs,
            acceptSearchEmpty: isSearch,
            requireSearchHref: isSearch ? cleanURL : nil
        )

        // N4: X not-found page — fail fast, do not burn 2×16s retries.
        if !(isStatus && finalProbe.statusNotFound) {
            // Retry error shells: rehydrate via home hard-load, then pushState (never assign search cold).
            // Status pages: also retry when ready=false with tweetCount=0 (SPA still hydrating).
            while (finalProbe.errorShell ||
                    (!finalProbe.ready && (isSearch || isStatus))) && retries < 2 {
                retries += 1
                method = "retry-pushstate"
                try await hardLoad(webView: webView, url: URL(string: "https://x.com/home")!)
                let home = await waitForPage(column: index, timeoutMs: 12_000, acceptSearchEmpty: false)
                if home.ready && !home.errorShell {
                    let soft = await attemptSoftNavigate(column: index, url: cleanURL)
                    if !soft.ok {
                        if isSearch {
                            let box = await attemptSoftSearch(column: index, url: cleanURL, healthy: true)
                            if !box.ok {
                                try await hardLoad(webView: webView, url: cleanURL)
                                method = "load-retry"
                            } else {
                                method = "retry-" + box.method
                            }
                        } else {
                            try await hardLoad(webView: webView, url: cleanURL)
                            method = "load-retry"
                        }
                    }
                } else {
                    try await hardLoad(webView: webView, url: cleanURL)
                    method = "load-retry"
                }
                finalProbe = await waitForPage(
                    column: index,
                    timeoutMs: settleTimeoutMs,
                    acceptSearchEmpty: isSearch,
                    requireSearchHref: isSearch ? cleanURL : nil
                )
                if isStatus && finalProbe.statusNotFound { break }
            }
        } else {
            method = method == "assign" || method == "load" ? method + "+notfound" : method
            print("[AgentBridge] status not-found fail-fast column=\(index) waitedMs=\(Int(Date().timeIntervalSince(started) * 1000)) url=\(cleanURL.absoluteString)")
        }

        // Status pages: conversation replies often hydrate after root. Scroll a few
        // times to harvest; if still only the root, report repliesLoaded=false
        // (WebKit may not paint replies while the window is occluded/hidden).
        var repliesLoaded: Bool? = nil
        if isStatus && finalProbe.ready && !finalProbe.errorShell && !finalProbe.statusNotFound {
            if finalProbe.tweets <= 1 {
                for _ in 0..<4 {
                    _ = try? await scroll(column: index, deltaY: 1400)
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    let again = await pageProbe(column: index)
                    if again.tweets > finalProbe.tweets {
                        finalProbe = again
                    }
                    if finalProbe.tweets > 1 { break }
                }
            }
            repliesLoaded = finalProbe.tweets > 1
            if repliesLoaded == false {
                print("[AgentBridge] status replies not loaded column=\(index) tweets=\(finalProbe.tweets) url=\(cleanURL.absoluteString) — window may be hidden/occluded; bring XDeck forward and re-read/scroll")
            }
        }

        entries[index]?.isLoading = false
        entries[index]?.loadFinishedAt = Date()
        entries[index]?.lastCardCount = finalProbe.tweets
        if let live = webView.url {
            entries[index]?.url = live
        }
        scheduleHydrateWatch(index: index)

        let waitedMs = Int(Date().timeIntervalSince(started) * 1000)
        if waitedMs > 10_000 {
            print("[AgentBridge] navigate slow column=\(index) waitedMs=\(waitedMs) method=\(method) tweets=\(finalProbe.tweets) url=\(cleanURL.absoluteString)")
        }
        let notFound = isStatus && finalProbe.statusNotFound
        return NavigateResult(
            ok: finalProbe.ready && !finalProbe.errorShell && !notFound,
            column: index,
            url: cleanURL.absoluteString,
            finalURL: finalProbe.href.isEmpty ? (webView.url?.absoluteString ?? cleanURL.absoluteString) : finalProbe.href,
            method: method,
            ready: finalProbe.ready,
            tweetCount: finalProbe.tweets,
            errorShell: finalProbe.errorShell,
            challenge: finalProbe.challenge,
            retries: retries,
            waitedMs: waitedMs,
            repliesLoaded: repliesLoaded,
            notFound: notFound
        )
    }

    private struct PageProbe {
        var ready = false
        var errorShell = false
        var challenge = false
        var tweets = 0
        var href = ""
        var statusNotFound = false
    }

    private func pageProbe(column index: Int) async -> PageProbe {
        do {
            let raw = try await evaluateJavaScript(column: index, script: AgentDOM.pageReadyJS)
            return Self.parsePageProbe(raw)
        } catch {
            return PageProbe(errorShell: true)
        }
    }

    private func waitForPage(
        column index: Int,
        timeoutMs: Int,
        acceptSearchEmpty: Bool,
        requireSearchHref: URL? = nil
    ) async -> PageProbe {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var last = PageProbe()
        var errorSince: Date?
        let wantQuery = requireSearchHref.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "q" })?
            .value }
        while Date() < deadline {
            last = await pageProbe(column: index)
            if last.challenge { return last }
            if let wantQuery {
                // Still on previous route or URL not updated — keep waiting.
                let hrefHasQuery = last.href.contains("q=") &&
                    (wantQuery.isEmpty || last.href.removingPercentEncoding?.contains(wantQuery) == true
                        || last.href.contains(wantQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? wantQuery))
                if !last.href.contains("/search") || !hrefHasQuery {
                    errorSince = nil
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    continue
                }
            }
            if last.ready { return last }
            // N4: not-found is a settled outcome — return as soon as detected.
            if last.statusNotFound { return last }
            if acceptSearchEmpty {
                // searchEmpty is folded into ready via pageReadyJS
            }
            if last.errorShell {
                if errorSince == nil { errorSince = Date() }
                // Require a stable Try-again shell (~1.2s) so mid-hydration blanks are not fatal.
                if let started = errorSince, Date().timeIntervalSince(started) >= 1.2 {
                    return last
                }
            } else {
                errorSince = nil
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        return last
    }

    private func attemptSoftNavigate(column index: Int, url: URL) async -> (ok: Bool, method: String) {
        do {
            let raw = try await evaluateJavaScript(column: index, script: AgentDOM.softNavigateJS(url: url))
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = obj["ok"] as? Bool, ok {
                let method = (obj["method"] as? String) ?? "pushstate"
                try? await Task.sleep(nanoseconds: 600_000_000)
                return (true, method)
            }
        } catch {
            return (false, "pushstate")
        }
        return (false, "pushstate")
    }

    private func attemptSoftSearch(column index: Int, url: URL, healthy: Bool) async -> (ok: Bool, method: String) {
        guard healthy else { return (false, "searchbox") }
        _ = try? await evaluateJavaScript(column: index, script: """
        (function() {
          var unhide = document.getElementById('xdeck-agent-unhide-header');
          if (!unhide) {
            unhide = document.createElement('style');
            unhide.id = 'xdeck-agent-unhide-header';
            unhide.textContent = 'header { display: flex !important; visibility: visible !important; opacity: 1 !important; }';
            (document.head || document.documentElement).appendChild(unhide);
          }
          var hide = document.getElementById('xdeck-hide-side-header');
          if (hide) hide.disabled = true;
          return true;
        })()
        """)
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            do {
                let raw = try await evaluateJavaScript(column: index, script: AgentDOM.softSearchJS(url: url))
                if let data = raw.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let ok = obj["ok"] as? Bool, ok {
                        let method = (obj["method"] as? String) ?? "searchbox"
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        return (true, method)
                    }
                    if let reason = obj["reason"] as? String {
                        if reason == "opened_explore" { return (false, "opened_explore") }
                        if reason == "error_shell" || reason == "not_ready" {
                            return (false, "searchbox")
                        }
                    }
                }
            } catch {
                return (false, "searchbox")
            }
        }
        return (false, "searchbox")
    }

    private func locationAssign(column index: Int, url: URL) async throws {
        let escaped = url.absoluteString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = "window.location.assign('\(escaped)'); true"
        _ = try await evaluateJavaScript(column: index, script: js)
    }

    private func hardLoad(webView: WKWebView, url: URL) async throws {
        let clean = Self.stripFailedScript(url)
        var request = URLRequest(url: clean)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
        // Allow provisional navigation to start before probing.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private static func isSameXSite(_ current: URL?, _ target: URL) -> Bool {
        guard let currentHost = current?.host?.lowercased(),
              let targetHost = target.host?.lowercased() else { return false }
        if currentHost == targetHost { return true }
        let x: (String) -> Bool = { $0 == "x.com" || $0.hasSuffix(".x.com") || $0 == "twitter.com" || $0.hasSuffix(".twitter.com") }
        return x(currentHost) && x(targetHost)
    }

    private static func stripFailedScript(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let items = (comps.queryItems ?? []).filter { $0.name.lowercased() != "failedscript" }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url ?? url
    }

    private static func parsePageProbe(_ raw: String) -> PageProbe {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PageProbe()
        }
        return PageProbe(
            ready: obj["ready"] as? Bool ?? false,
            errorShell: obj["errorShell"] as? Bool ?? false,
            challenge: obj["challenge"] as? Bool ?? false,
            tweets: (obj["tweets"] as? Int) ?? (obj["tweets"] as? NSNumber)?.intValue ?? 0,
            href: obj["href"] as? String ?? "",
            statusNotFound: obj["statusNotFound"] as? Bool ?? false
        )
    }

    /// - Parameter resetHydrateHeal: when true (manual/agent reload), allow another
    ///   automatic blank-column heal. Self-heal passes false to avoid loops.
    func reload(column index: Int, resetHydrateHeal: Bool = true) throws {
        guard let webView = entries[index]?.webView else {
            throw AgentBridgeError.columnNotFound(index)
        }
        entries[index]?.hydrateTask?.cancel()
        entries[index]?.isLoading = true
        entries[index]?.loadFinishedAt = nil
        if resetHydrateHeal {
            entries[index]?.hydrateHealAttempted = false
        }
        webView.reload()
    }

    func scroll(column index: Int, deltaY: Int) async throws -> String {
        try await evaluateJavaScript(column: index, script: AgentDOM.scrollJS(deltaY: deltaY))
    }

    private static func escapeJSONString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private static func stringifyJSResult(_ result: Any?) -> String {
        switch result {
        case nil, is NSNull:
            return "null"
        case let value as String:
            return escapeJSONString(value)
        case let value as NSNumber:
            // Distinguish booleans from numbers (JS booleans bridge as NSNumber).
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue ? "true" : "false"
            }
            return value.stringValue
        case let value as [Any]:
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value),
               let encoded = String(data: data, encoding: .utf8) {
                return encoded
            }
            return "null"
        case let value as [String: Any]:
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value),
               let encoded = String(data: data, encoding: .utf8) {
                return encoded
            }
            return "null"
        default:
            return "\"\(String(describing: result))\""
        }
    }
}

enum AgentBridgeError: LocalizedError {
    case columnNotFound(Int)
    case jsError(String)
    case unauthorized
    case badRequest(String)
    case methodNotAllowed
    case notFound
    /// Eval routes when `XDECK_AGENT_EVAL` is unset — HTTP **404** (unregistered).
    case evalDisabled
    case notImplemented(String)
    /// Localhost bind failed (EADDRINUSE or other) — bridge is down; no wildcard fallback.
    case bindFailed(String)

    var errorDescription: String? {
        switch self {
        case .columnNotFound(let i):
            return "Column \(i) not found or WebView not registered"
        case .jsError(let message):
            return "JavaScript error: \(message)"
        case .unauthorized:
            return "Unauthorized — provide Authorization: Bearer <token>"
        case .badRequest(let message):
            return message
        case .methodNotAllowed:
            return "Method not allowed"
        case .notFound:
            return "Not found"
        case .evalDisabled:
            return "Eval disabled — set XDECK_AGENT_EVAL=1 on the XDeck process to enable POST /eval (HTTP 404 when unset)"
        case .notImplemented(let feature):
            return "\(feature) is not implemented. This bridge is a read/navigate lab telescope — no post/reply/like/click tools. Do not use eval_js to mutate the page unless a human explicitly asks."
        case .bindFailed(let message):
            return message
        }
    }

    var statusCode: Int {
        switch self {
        case .unauthorized: return 401
        case .columnNotFound, .notFound, .evalDisabled: return 404
        case .badRequest: return 400
        case .notImplemented: return 501
        case .methodNotAllowed: return 405
        case .jsError, .bindFailed: return 500
        }
    }
}
