import Foundation

/// Maintained JS helpers injected via `evaluateJavaScript` for the agent bridge.
/// Prefer these over ad-hoc agent CSS — x.com `data-testid` still churns.
enum AgentDOM {
    /// Parse visible tweet cards in the column WebView.
    static let extractTweetsJS = #"""
    (function() {
      function absUrl(href) {
        if (!href) return null;
        if (href.indexOf('http') === 0) return href.split('?')[0];
        return 'https://x.com' + href.split('?')[0];
      }
      var tweets = [];
      var articles = document.querySelectorAll('article[data-testid="tweet"]');
      for (var i = 0; i < articles.length; i++) {
        var article = articles[i];
        var id = null;
        var url = null;
        var links = article.querySelectorAll('a[href*="/status/"]');
        for (var j = 0; j < links.length; j++) {
          var href = links[j].getAttribute('href') || '';
          var m = href.match(/\/status\/(\d+)/);
          if (m) {
            id = m[1];
            url = absUrl(href);
            break;
          }
        }
        var author = null;
        var handle = null;
        var userName = article.querySelector('[data-testid="User-Name"]');
        if (userName) {
          var raw = ((document.visibilityState === 'hidden'
            ? userName.textContent
            : userName.innerText) || userName.textContent || '').trim();
          var lines = raw.split('\n').map(function(s) { return s.trim(); }).filter(Boolean);
          if (lines.length) author = lines[0];
          var hm = raw.match(/@([A-Za-z0-9_]+)/);
          if (hm) handle = hm[1];
          if (!handle) {
            var userLinks = userName.querySelectorAll('a[href^="/"]');
            for (var k = 0; k < userLinks.length; k++) {
              var uh = userLinks[k].getAttribute('href') || '';
              if (/^\/[A-Za-z0-9_]+\/?$/.test(uh) && uh.indexOf('/status/') < 0) {
                handle = uh.replace(/^\//, '').replace(/\/$/, '');
                break;
              }
            }
          }
        }
        var textEl = article.querySelector('[data-testid="tweetText"]');
        // Prefer textContent when the column WebView is visibility:hidden
        // (off-screen columns): innerText is then empty by CSS rules.
        var text = '';
        if (textEl) {
          text = (document.visibilityState === 'hidden'
            ? (textEl.textContent || '')
            : (textEl.innerText || textEl.textContent || '')).trim();
        }
        var timeEl = article.querySelector('time');
        var time = null;
        if (timeEl) {
          time = timeEl.getAttribute('datetime') || (timeEl.textContent || null);
        }
        tweets.push({
          id: id,
          author: author,
          handle: handle,
          text: text,
          time: time,
          url: url
        });
      }
      return tweets;
    })()
    """#

    static func scrollJS(deltaY: Int) -> String {
        """
        (function() {
          var dy = \(deltaY);
          function isScrollable(el) {
            if (!el || el === document.body || el === document.documentElement) return false;
            var style = window.getComputedStyle(el);
            var oy = style.overflowY;
            return el.scrollHeight > el.clientHeight + 40 &&
              (oy === 'auto' || oy === 'scroll' || oy === 'overlay');
          }
          var start = document.querySelector('[data-testid="primaryColumn"]') ||
            document.querySelector('main') ||
            document.body;
          var el = start;
          while (el && el !== document.documentElement) {
            if (isScrollable(el)) {
              el.scrollBy(0, dy);
              return { scrolled: dy, via: 'element', tag: el.tagName };
            }
            el = el.parentElement;
          }
          var root = document.scrollingElement || document.documentElement;
          root.scrollBy(0, dy);
          window.scrollBy(0, dy);
          return { scrolled: dy, via: 'window', tag: 'WINDOW' };
        })()
        """
    }

    static func innerTextJS(maxChars: Int) -> String {
        """
        (function() {
          var body = document.body;
          if (!body) return '';
          var t = document.visibilityState === 'hidden'
            ? (body.textContent || '')
            : (body.innerText || body.textContent || '');
          if (t.length > \(maxChars)) t = t.slice(0, \(maxChars));
          return t;
        })()
        """
    }
}
