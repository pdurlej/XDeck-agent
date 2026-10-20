import SwiftUI
import WebKit
import AppKit

struct WebView: NSViewRepresentable {
    typealias NSViewType = WKWebView

    @Binding var isLoading: Bool
    @Binding var url: URL
    @Binding var alertMessage: String?
    @Binding var messageFromWebView: String?
    var scriptExecutionRequest: String? = nil

    @AppStorage("pageZoom") var pageZoom: Double = 1

    var scriptExecutionToken: Int = 0
    var refreshSwitch: Bool = false
    var configuration: WKWebViewConfiguration? = nil

    /// When set, this WebView registers itself with `ColumnRegistry` for the agent bridge.
    var columnIndex: Int? = nil
    var columnType: String? = nil

    func makeNSView(context: Context) -> WKWebView {
        let webView: WKWebView
        if let configuration = configuration {
            webView = WKWebView(frame: .zero, configuration: configuration)
        } else {
            webView = WKWebView()
        }
        // Pretend Safari because 𝕏 bans the user agent of WebView
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        let request = URLRequest(url: url)
        webView.load(request)

        if let columnIndex, let columnType {
            Task { @MainActor in
                ColumnRegistry.shared.register(
                    index: columnIndex,
                    type: columnType,
                    webView: webView,
                    url: url,
                    isLoading: true
                )
            }
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if url != context.coordinator.lastUrl {
            // Agent navigate owns this WebView's location (and forYou/following share $homeUrl).
            // Absorb binding changes without WKWebView.load — otherwise siblings fight SPA nav.
            if ColumnRegistry.shared.shouldIgnoreBindingLoad(webView) {
                context.coordinator.lastUrl = url
            } else if webView.url?.absoluteString == url.absoluteString {
                context.coordinator.lastUrl = url
            } else {
                let request = URLRequest(url: url)
                context.coordinator.lastUrl = url
                webView.load(request)
            }
        }
        if refreshSwitch != context.coordinator.refreshSwitch {
            ColumnRegistry.shared.clearIgnoreBindingLoad(webView)
            let request = URLRequest(url: url)
            webView.load(request)
            context.coordinator.refreshSwitch = refreshSwitch
        } else if let script = scriptExecutionRequest, scriptExecutionToken != context.coordinator.lastHandledScriptToken {
            webView.evaluateJavaScript(script)
            context.coordinator.lastHandledScriptToken = scriptExecutionToken
        }
        if webView.pageZoom != pageZoom {
            webView.pageZoom = CGFloat(pageZoom)
        }

        if let columnIndex {
            Task { @MainActor in
                // Prefer live WKWebView URL while agent owns navigation.
                let liveURL = ColumnRegistry.shared.shouldIgnoreBindingLoad(webView)
                    ? (webView.url ?? url) : url
                ColumnRegistry.shared.update(index: columnIndex, url: liveURL, isLoading: isLoading)
            }
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        if let columnIndex = coordinator.owner.columnIndex {
            Task { @MainActor in
                ColumnRegistry.shared.unregister(index: columnIndex, webView: nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(owner: self)
    }
}

class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let owner: WebView
    var lastUrl: URL
    var refreshSwitch: Bool
    var lastHandledScriptToken: Int

    init(owner: WebView) {
        self.owner = owner
        self.lastUrl = owner.url
        self.refreshSwitch = false
        self.lastHandledScriptToken = owner.scriptExecutionToken
        super.init()
        owner.configuration?.userContentController.add(self, name: WebViewConfigurations.handlerName)
    }

    // MARK: WKNavigationDelegate
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        owner.isLoading = true
        if let columnIndex = owner.columnIndex {
            Task { @MainActor in
                ColumnRegistry.shared.update(index: columnIndex, url: owner.url, isLoading: true)
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner.isLoading = false
        if let finished = webView.url {
            lastUrl = finished
            // Agent-driven nav must not write back into shared bindings (forYou+following
            // both use $homeUrl) — that forced sibling columns onto search and raced loads.
            if !ColumnRegistry.shared.shouldIgnoreBindingLoad(webView) {
                owner.url = finished
            }
        }
        if let columnIndex = owner.columnIndex {
            Task { @MainActor in
                ColumnRegistry.shared.update(index: columnIndex, url: webView.url ?? owner.url, isLoading: false)
            }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if case .linkActivated = navigationAction.navigationType, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: WKUIDelegate
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        owner.alertMessage = message
        print("🚨️ \(message)")
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection
        openPanel.begin { response in
            if response == .OK {
                completionHandler(openPanel.urls)
            } else {
                completionHandler(nil)
            }
        }
    }

    // MARK: WKScriptMessageHandler
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebViewConfigurations.handlerName else { return }
        print("[WKScriptMessage] \(message.body)")
        owner.messageFromWebView = message.body as? String
    }
}
