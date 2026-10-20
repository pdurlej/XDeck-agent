import SwiftUI
import WebKit

/// Offscreen (behind / near-invisible) WKWebViews for agents.
/// Kept in the window hierarchy with a non-zero frame so `document.visibilityState`
/// stays `visible` and infinite scroll / lazy load keep working. Shares the default
/// `WKWebsiteDataStore` (same login cookies) as human columns.
struct AgentColumnsHost: View {
    private var indices: [Int] { AgentColumnLeases.shared.agentIndices }

    var body: some View {
        GeometryReader { geo in
            let width = max(360, min(520, geo.size.width * 0.4))
            let height = max(600, geo.size.height)
            HStack(spacing: 8) {
                ForEach(indices, id: \.self) { index in
                    AgentColumnSlot(index: index, width: width, height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Near-zero alpha: still painted / attached so WebKit Page Visibility stays visible.
        // Fully removed or zero-size views flip to `hidden` and break lazy load.
        .opacity(0.02)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One agent column with its own URL binding (avoids sibling navigate races).
private struct AgentColumnSlot: View {
    let index: Int
    let width: CGFloat
    let height: CGFloat

    @State private var url = URL(string: "https://x.com/home")!
    @State private var isLoading = false
    @State private var alertMessage: String? = nil
    @State private var messageFromWebView: String? = nil

    var body: some View {
        WebView(
            isLoading: $isLoading,
            url: $url,
            alertMessage: $alertMessage,
            messageFromWebView: $messageFromWebView,
            scriptExecutionRequest: nil,
            scriptExecutionToken: 0,
            refreshSwitch: false,
            configuration: WKWebViewConfiguration.agentSharedSessionConfiguration(
                onLoadScripts: [.global, .hideSideHeader, .hidePostArea]
            ),
            columnIndex: index,
            columnType: "agent",
            columnVisible: false
        )
        .frame(width: width, height: height)
    }
}

extension WKWebViewConfiguration {
    /// Explicit default data store — same cookie jar as human deck columns.
    static func agentSharedSessionConfiguration(
        onLoadScripts: [WebViewConfigurations.OnLoadScript]
    ) -> WKWebViewConfiguration {
        let configuration = WebViewConfigurations.makeConfiguration(onLoadScripts: onLoadScripts)
        configuration.websiteDataStore = .default()
        return configuration
    }
}
