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

    /// Detect login / CAPTCHA / challenge / SPA error shells so agents can set needs_human
    /// instead of treating chrome mush as a timeline.
    static let challengeProbeJS = #"""
    (function() {
      var href = String(location.href || '');
      var path = String(location.pathname || '');
      var body = document.body;
      var text = '';
      if (body) {
        text = document.visibilityState === 'hidden'
          ? (body.textContent || '')
          : (body.innerText || body.textContent || '');
      }
      if (text.length > 8000) text = text.slice(0, 8000);
      var lower = text.toLowerCase();
      var reasons = [];
      var hasTweets = !!document.querySelector('article[data-testid="tweet"]');
      var hasPrimary = !!document.querySelector('[data-testid="primaryColumn"]');

      if (/\/i\/flow\/login|\/login\/?$|\/i\/flow\/signup|\/account\/access/i.test(href) ||
          /\/i\/flow\/login|\/login\/?$|\/account\/access/i.test(path)) {
        reasons.push('login_url');
      }
      if (/captcha|arkose|funcaptcha|\/challenge/i.test(href) ||
          /verify you(?:'| a)?re (?:a )?human|are you a robot|unusual activity|confirm you(?:'| a)?re not a bot|complete the challenge/i.test(lower)) {
        reasons.push('challenge_or_captcha');
      }
      if (document.querySelector(
        'input[autocomplete="username"], input[name="password"], [data-testid="LoginForm"], [data-testid="loginButton"], form[action*="login"]'
      )) {
        reasons.push('login_form');
      }
      if (/log in to (?:x|twitter)|sign in to (?:x|twitter)|to get started,? log in/i.test(lower) && !hasTweets) {
        reasons.push('login_prompt');
      }
      // x.com SPA error shell (often after brittle navigate). Require a *visible*
      // error node or strong body copy — do not treat empty mid-load timelines
      // or CSS-only `.errorContainer` rules as failure.
      var errEl = document.querySelector('.errorContainer');
      var errCopy = errEl
        ? ((errEl.innerText || errEl.textContent || '').trim())
        : '';
      var errVisible = errCopy.length > 0 &&
        /something went wrong|try again|javascript is disabled|js disabled/i.test(errCopy);
      var bodyError = /something went wrong\.?\s*try again|this page (?:isn.?t|is not) available|page doesn.?t exist|rate limit(?:ed)?|temporarily restricted|javascript is disabled/i.test(lower);
      if (!hasTweets && !hasPrimary && (errVisible || bodyError)) {
        reasons.push('error_shell');
      }

      // Dedupe while preserving order
      var seen = {};
      var unique = [];
      for (var i = 0; i < reasons.length; i++) {
        if (!seen[reasons[i]]) {
          seen[reasons[i]] = true;
          unique.push(reasons[i]);
        }
      }
      return {
        needs_human: unique.length > 0,
        reasons: unique,
        href: href,
        hasTweets: hasTweets,
        hasPrimaryColumn: hasPrimary
      };
    })()
    """#

    /// Probe whether the column SPA is usable after navigate (tweets, empty search, or error shell).
    static let pageReadyJS = #"""
    (function() {
      var href = String(location.href || '');
      var path = String(location.pathname || '');
      var body = document.body;
      var text = '';
      if (body) {
        text = document.visibilityState === 'hidden'
          ? (body.textContent || '')
          : (body.innerText || body.textContent || '');
      }
      if (text.length > 6000) text = text.slice(0, 6000);
      var lower = text.toLowerCase();
      var tweets = document.querySelectorAll('article[data-testid="tweet"]').length;
      var primary = !!document.querySelector('[data-testid="primaryColumn"]');
      var errEl = document.querySelector('.errorContainer');
      var errCopy = errEl ? ((errEl.innerText || errEl.textContent || '').trim()) : '';
      var tryAgain = [].some.call(document.querySelectorAll('button,a'), function(el) {
        return /^try again$/i.test(((el.innerText || el.textContent || '') + '').trim());
      });
      var errorShell = (!tweets && !primary && (
        tryAgain ||
        (errCopy.length > 0 && /something went wrong|try again|javascript is disabled/i.test(errCopy)) ||
        /failedscript=/i.test(href) ||
        /something went wrong\.?\s*try again|javascript is disabled/i.test(lower)
      ));
      var searchPage = /\/search/i.test(path);
      var searchEmpty = searchPage && primary && tweets === 0 &&
        /no results|nie znaleziono|nothing matched|try searching for something else|brak wyników/i.test(lower);
      var challenge = /\/i\/flow\/login|\/account\/access|arkose|funcaptcha/i.test(href) ||
        /verify you(?:'| a)?re (?:a )?human|confirm you(?:'| a)?re not a bot|complete the challenge/i.test(lower);
      // Search: only "ready" once tweets land or empty-state copy — not mere primaryColumn
      // (pushState keeps old chrome briefly before results hydrate).
      var ready = !errorShell && !challenge && (
        tweets > 0 || searchEmpty || (!searchPage && primary)
      );
      return {
        ready: ready,
        errorShell: errorShell,
        challenge: challenge,
        searchPage: searchPage,
        searchEmpty: searchEmpty,
        tweets: tweets,
        primary: primary,
        href: href,
        title: document.title || ''
      };
    })()
    """#

    /// Same-origin SPA navigate without full document reload.
    /// Full `location.assign` / `WKWebView.load` often paints x.com `?failedScript=` error shells
    /// under our injected user scripts; `history.pushState` + `popstate` keeps React alive.
    static func softNavigateJS(url: URL) -> String {
        let escaped = url.absoluteString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
          var targetUrl = '\(escaped)';
          try {
            var u = new URL(targetUrl, location.origin);
            if (u.origin !== location.origin) {
              return { ok: false, reason: 'cross_origin' };
            }
            var probeTweets = document.querySelectorAll('article[data-testid="tweet"]').length;
            var probePrimary = !!document.querySelector('[data-testid="primaryColumn"]');
            var tryAgain = [].some.call(document.querySelectorAll('button,a'), function(el) {
              return /^try again$/i.test(((el.innerText || el.textContent || '') + '').trim());
            });
            if (tryAgain && !probePrimary && !probeTweets) {
              return { ok: false, reason: 'error_shell' };
            }
            if (!probePrimary && !probeTweets) {
              return { ok: false, reason: 'not_ready' };
            }
            var next = u.pathname + u.search + u.hash;
            var cur = location.pathname + location.search + location.hash;
            if (next === cur) {
              return { ok: true, method: 'noop', href: location.href };
            }
            history.pushState({}, '', next);
            try {
              window.dispatchEvent(new PopStateEvent('popstate', { state: history.state }));
            } catch (_) {
              window.dispatchEvent(new Event('popstate'));
            }
            return { ok: true, method: 'pushstate', href: location.href };
          } catch (e) {
            return { ok: false, reason: String(e && e.message ? e.message : e) };
          }
        })()
        """
    }

    /// SearchBox submit (Explore exposes it; Home with hideSideHeader often does not).
    static func softSearchJS(url: URL) -> String {
        let escaped = url.absoluteString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
          var targetUrl = '\(escaped)';
          try {
            var u = new URL(targetUrl, location.origin);
            if (u.pathname.indexOf('/search') !== 0) {
              return { ok: false, reason: 'not_search' };
            }
            var q = u.searchParams.get('q') || '';
            if (!q) return { ok: false, reason: 'empty_query' };

            var probeTweets = document.querySelectorAll('article[data-testid="tweet"]').length;
            var probePrimary = !!document.querySelector('[data-testid="primaryColumn"]');
            var tryAgain = [].some.call(document.querySelectorAll('button,a'), function(el) {
              return /^try again$/i.test(((el.innerText || el.textContent || '') + '').trim());
            });
            if (tryAgain && !probePrimary && !probeTweets) {
              return { ok: false, reason: 'error_shell' };
            }
            if (!probePrimary && !probeTweets) {
              return { ok: false, reason: 'not_ready' };
            }

            var unhide = document.getElementById('xdeck-agent-unhide-header');
            if (!unhide) {
              unhide = document.createElement('style');
              unhide.id = 'xdeck-agent-unhide-header';
              unhide.textContent = 'header { display: flex !important; visibility: visible !important; opacity: 1 !important; }';
              (document.head || document.documentElement).appendChild(unhide);
            }
            var hide = document.getElementById('xdeck-hide-side-header');
            if (hide) hide.disabled = true;

            var input = document.querySelector('[data-testid="SearchBox_Search_Input"]') ||
              document.querySelector('input[aria-label="Search query"]') ||
              document.querySelector('input[aria-label="Wyszukiwanie"]') ||
              document.querySelector('input[placeholder*="Search"]') ||
              document.querySelector('input[placeholder*="Szukaj"]');
            if (!input) {
              var explore = document.querySelector('a[href="/explore"]');
              if (explore) {
                explore.click();
                return { ok: false, reason: 'opened_explore' };
              }
              return { ok: false, reason: 'no_searchbox' };
            }

            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
            input.focus();
            nativeSetter.call(input, q);
            input.dispatchEvent(new Event('input', { bubbles: true }));
            input.dispatchEvent(new Event('change', { bubbles: true }));
            try {
              input.dispatchEvent(new InputEvent('input', { bubbles: true, data: q, inputType: 'insertText' }));
            } catch (_) {}
            ['keydown', 'keypress', 'keyup'].forEach(function(type) {
              input.dispatchEvent(new KeyboardEvent(type, {
                key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true
              }));
            });
            return { ok: true, method: 'searchbox', query: q, href: location.href };
          } catch (e) {
            return { ok: false, reason: String(e && e.message ? e.message : e) };
          }
        })()
        """
    }

    static let clickTryAgainJS = #"""
    (function() {
      var btn = [].find.call(document.querySelectorAll('button,a'), function(el) {
        return /^try again$/i.test(((el.innerText || el.textContent || '') + '').trim());
      });
      if (!btn) return { ok: false, reason: 'no_button' };
      try { btn.click(); return { ok: true }; }
      catch (e) { return { ok: false, reason: String(e) }; }
    })()
    """#
}
