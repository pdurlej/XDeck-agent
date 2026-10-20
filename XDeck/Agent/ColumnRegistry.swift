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
    }

    private struct Entry {
        var type: String
        weak var webView: WKWebView?
        var url: URL?
        var isLoading: Bool
    }

    private var entries: [Int: Entry] = [:]
    /// Best-effort logged-in handle scraped from the profile column / login flow.
    var userHandle: String?

    private init() {}

    func register(index: Int, type: String, webView: WKWebView, url: URL?, isLoading: Bool) {
        entries[index] = Entry(type: type, webView: webView, url: url, isLoading: isLoading)
    }

    func update(index: Int, url: URL?, isLoading: Bool?) {
        guard var entry = entries[index] else { return }
        if let url { entry.url = url }
        if let isLoading { entry.isLoading = isLoading }
        entries[index] = entry
    }

    func unregister(index: Int, webView: WKWebView) {
        guard let entry = entries[index], entry.webView === webView else { return }
        entries.removeValue(forKey: index)
    }

    func snapshot() -> [ColumnSnapshot] {
        entries.keys.sorted().compactMap { index in
            guard let entry = entries[index] else { return nil }
            return ColumnSnapshot(
                index: index,
                type: entry.type,
                url: entry.url?.absoluteString,
                isLoading: entry.isLoading,
                hasWebView: entry.webView != nil
            )
        }
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
    /// Prefer same-origin `location.assign` (keeps SPA session); fall back to `load`.
    func navigate(column index: Int, to url: URL) async throws {
        guard let webView = entries[index]?.webView else {
            throw AgentBridgeError.columnNotFound(index)
        }
        entries[index]?.url = url
        entries[index]?.isLoading = true
        let currentHost = webView.url?.host?.lowercased()
        let targetHost = url.host?.lowercased()
        let sameSite = currentHost != nil && targetHost != nil &&
            (currentHost == targetHost
                || (currentHost!.hasSuffix("x.com") && targetHost!.hasSuffix("x.com"))
                || (currentHost!.hasSuffix("twitter.com") && targetHost!.hasSuffix("twitter.com")))
        if sameSite {
            let escaped = url.absoluteString
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let js = "window.location.assign('\(escaped)'); true"
            _ = try await evaluateJavaScript(column: index, script: js)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func reload(column index: Int) throws {
        guard let webView = entries[index]?.webView else {
            throw AgentBridgeError.columnNotFound(index)
        }
        entries[index]?.isLoading = true
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
    case notImplemented(String)

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
        case .notImplemented(let feature):
            return "\(feature) is not implemented. This bridge is a read/navigate lab telescope — no post/reply/like/click tools. Do not use eval_js to mutate the page unless a human explicitly asks."
        }
    }

    var statusCode: Int {
        switch self {
        case .unauthorized: return 401
        case .columnNotFound, .notFound: return 404
        case .badRequest: return 400
        case .notImplemented: return 501
        case .methodNotAllowed: return 405
        case .jsError: return 500
        }
    }
}
