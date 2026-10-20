import Foundation
import WebKit

struct WebViewConfigurations {
    enum OnLoadScript {
        case global
        case findUserName
        case findThemeColor
        case clickForYouTab
        case hidePostArea
        case clickFollowingTab
        case hideSideHeader
        case hideAds
        case detectMediaOverlay(columnIndex: Int)

        var scriptContent: String {
            switch self {
            case .global: return WebViewConfigurations.global
            case .findUserName: return WebViewConfigurations.findUserName
            case .findThemeColor: return WebViewConfigurations.findThemeColor
            case .clickForYouTab: return WebViewConfigurations.clickForYouTab
            case .hidePostArea: return WebViewConfigurations.hidePostArea
            case .clickFollowingTab: return WebViewConfigurations.clickFollowingTab
            case .hideSideHeader: return WebViewConfigurations.hideSideHeader
            case .hideAds: return WebViewConfigurations.hideAds
            case .detectMediaOverlay(let columnIndex): return WebViewConfigurations.detectMediaOverlay(columnIndex: columnIndex)
            }
        }

        var runAfterLoad: Bool {
            switch self {
            case .findUserName, .findThemeColor, .clickForYouTab, .clickFollowingTab, .hideSideHeader, .hidePostArea, .hideAds:
                return true
            case .global, .detectMediaOverlay:
                return false
            }
        }
    }

    static let handlerName = "handler";

    static func makeConfiguration(onLoadScripts: [OnLoadScript]) -> WKWebViewConfiguration {
        let script = [
            onLoadScripts.filter({ !$0.runAfterLoad }).map(\.scriptContent).joined(separator: "\n"),
            wrapOnLoad(contents: onLoadScripts.filter({ $0.runAfterLoad }).map(\.scriptContent)),
        ].joined(separator: "\n")
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController
        let userScript = WKUserScript(
            source: script,
            injectionTime: .atDocumentStart, forMainFrameOnly: true)
        userContentController.addUserScript(userScript)
        return configuration
    }

    private static let global: String = """
        // Bridge debug hooks must never throw — x.com treats user-script exceptions as
        // `?failedScript=` SPA error shells (Try again). Keep originals intact.
        (function() {
            function bridgeLog(prefix, args) {
                try {
                    const raw = Array.prototype.slice.call(args).map(function(v) {
                        try { return typeof v === 'string' ? v : JSON.stringify(v); }
                        catch (_) { return String(v); }
                    }).join(' ').slice(0, 800);
                    const message = JSON.stringify({ type: "debug", body: prefix + " " + raw });
                    webkit.messageHandlers.\(Self.handlerName).postMessage(message);
                } catch (_) {}
            }
            window.onerror = function(msg, url, line, column, error) {
                bridgeLog("❌️", [msg, url, line, column]);
                return false;
            };
            const c = window.console;
            if (c) {
                const levels = [
                    ["error", "❌️"],
                    ["warn", "⚠️"],
                    ["info", "ℹ️"],
                    ["log", "ℹ️"]
                ];
                levels.forEach(function(pair) {
                    const name = pair[0];
                    const prefix = pair[1];
                    const original = c[name] && c[name].bind ? c[name].bind(c) : null;
                    c[name] = function() {
                        bridgeLog(prefix, arguments);
                        if (original) {
                            try { return original.apply(c, arguments); } catch (_) {}
                        }
                    };
                });
            }
        })();

        \(getElementsByXPath)

        \(waitForElement)
    """

    private static let hidePostArea: String = """
        const style = document.createElement('style');
        style.type = 'text/css';
        style.innerHTML = "div:has(> main):has(> :nth-child(4)) > main div:has(> div > div[role='progressbar']) { display: none; }";
        (document.head || document.documentElement).appendChild(style);
    """

    private static let findUserName: String = """
        waitForElement("a[aria-label='Profile'], a[data-testid='AppTabBar_Profile_Link']", 0, (element) => {
            const href = element.getAttribute('href') || element.href || '';
            let userName = null;
            try {
                const url = new URL(href, window.location.origin);
                const segments = url.pathname.split('/').filter(Boolean);
                userName = segments[0] || null;
            } catch (_) {}
            if (userName) {
                const message = JSON.stringify({ type: "userName", body: userName });
                webkit.messageHandlers.\(Self.handlerName).postMessage(message);
            }
        });
    """

    private static let findThemeColor: String = """
        waitForElement("meta[name='theme-color']", 0, (meta) => {
            // The theme-color meta tag can be rewritten multiple times while the SPA hydrates
            // (e.g. a default value first, then the value derived from the night_mode cookie),
            // so wait for it to stop changing before reporting it back.
            let debounceTimer = null;
            const reportWhenStable = () => {
                clearTimeout(debounceTimer);
                debounceTimer = setTimeout(() => {
                    const message = JSON.stringify({ type: "themeColor", body: meta.getAttribute('content') });
                    webkit.messageHandlers.\(Self.handlerName).postMessage(message);
                }, 500);
            };
            new MutationObserver(reportWhenStable).observe(meta, { attributes: true, attributeFilter: ['content'] });
            reportWhenStable();
        });
    """

    private static let hideSideHeader: String = """
        const style = document.createElement('style');
        style.type = 'text/css';
        style.id = 'xdeck-hide-side-header';
        style.innerHTML = "header { display: none !important; }";
        (document.head || document.documentElement).appendChild(style);
        """

    private static let clickForYouTab: String = """
        waitForElement("a[href='/home'][role='tab']", 0, (element) => {
            // Only on the home timeline — clicking For You after agent search nav undoes it.
            if (location.pathname !== '/home' && location.pathname !== '/') return;
            element.click();
        });
        """

    private static let clickFollowingTab: String = """
        waitForElement("a[href='/home'][role='tab']", 1, (element) => {
            if (location.pathname !== '/home' && location.pathname !== '/') return;
            element.click();
        });
        """

    private static func wrapOnLoad(contents: [String]) -> String {
        return """
            \(waitForElement)
            document.addEventListener('DOMContentLoaded', () => {
                \(contents.map {
                    """
                    (() => {
                        \($0)
                    })();
                    """
                }.joined(separator: "\n"))
            });
            """
    }

    private static let waitForElement: String = """
        function waitForElement(selector, index, callback, once=true) {
            const start = () => {
                if (!document.body) {
                    setTimeout(start, 50);
                    return;
                }
                const existing = document.querySelectorAll(selector)[index];
                if (existing) {
                    try { callback(existing); } catch (_) {}
                    if (once) return;
                }
                const observer = new MutationObserver((mutationsList, observer) => {
                    const element = document.querySelectorAll(selector)[index];
                    if (element) {
                        try { callback(element); } catch (_) {}
                        if (once) {
                            observer.disconnect();
                        }
                    }
                });
                observer.observe(document.body, { childList: true, subtree: true });
            };
            start();
        }
        """

    private static let getElementsByXPath: String = """
        function getElementsByXPath(xpath, parent) {
          let results = [];
          let query = document.evaluate(
            xpath,
            parent || document,
            null,
            XPathResult.ORDERED_NODE_SNAPSHOT_TYPE,
            null
          );
          for (let i = 0, length = query.snapshotLength; i < length; i++) {
            results.push(query.snapshotItem(i));
          }
          return results;
        }
        """

    static let hideAds: String = """
        function hideAds() {
          const cells = document.querySelectorAll('div[data-testid="cellInnerDiv"]');
          cells.forEach((cell) => {
            // Ads carry *-impression-pixel elements; placementTracking alone also wraps regular video tweets
            if (cell.querySelector('[data-testid$="-impression-pixel"]')) {
              cell.style.display = "none";
            }
          });
        }

        if (!window.hideAdsMutationObserver) {
          let hideAdsTimer;
          let observer = new MutationObserver(() => {
            clearTimeout(hideAdsTimer);
            hideAdsTimer = setTimeout(hideAds, 100);
          });

          if (document.body) {
            observer.observe(document.body, {
              childList: true,
              subtree: true,
            });
            window.hideAdsMutationObserver = observer;
          }
        }

        try { hideAds(); } catch (_) {}
        """
    static let showAds: String = """
        (() => {
          if (window.hideAdsMutationObserver) {
            window.hideAdsMutationObserver.disconnect();
            window.hideAdsMutationObserver = null;
          }

          const cells = document.querySelectorAll('div[data-testid="cellInnerDiv"]');
          cells.forEach((cell) => {
            if (cell.querySelector('[data-testid$="-impression-pixel"]')) {
              cell.style.display = "flex";
            }
          });
        })();
    """

    private static func detectMediaOverlay(columnIndex: Int) -> String {
        return """
            (function() {
                var mediaExpanded = false;
                const originalPushState = history.pushState;
                history.pushState = function() {
                    originalPushState.apply(this, arguments);
                    const url = window.location.href;
                    if (!mediaExpanded && /\\/(photo|video)\\/\\d+/.test(url)) {
                        mediaExpanded = true;
                        const message = JSON.stringify({ type: "mediaOverlay", body: String(\(columnIndex)) });
                        webkit.messageHandlers.\(Self.handlerName).postMessage(message);
                    }
                };
                window.addEventListener('popstate', function() {
                    const url = window.location.href;
                    if (mediaExpanded && !/\\/(photo|video)\\/\\d+/.test(url)) {
                        mediaExpanded = false;
                        const message = JSON.stringify({ type: "mediaOverlay", body: "close" });
                        webkit.messageHandlers.\(Self.handlerName).postMessage(message);
                    }
                });
            })();
        """
    }
}

