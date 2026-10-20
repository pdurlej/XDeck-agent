import Foundation

/// Maintained JS helpers injected via `evaluateJavaScript` for the agent bridge.
/// Prefer these over ad-hoc agent CSS — x.com `data-testid` still churns.
enum AgentDOM {
    /// Parse visible tweet cards in the column WebView.
    /// Emits isAd, retweetedBy, quoted, media when present. Status URLs are
    /// normalized (never `/analytics`). Ad detection is locale-independent
    /// (cell impression pixels — same signal as hideAds).
    static let extractTweetsJS = #"""
    (function() {
      function visibleText(el) {
        if (!el) return '';
        return (document.visibilityState === 'hidden'
          ? (el.textContent || '')
          : (el.innerText || el.textContent || '')).trim();
      }
      function absUrl(href) {
        if (!href) return null;
        if (href.indexOf('http') === 0) return href.split('?')[0];
        return 'https://x.com' + href.split('?')[0];
      }
      /** Prefer /status/<id>; strip /analytics|/photo|/video|/likes suffixes. */
      function statusFromHref(href) {
        if (!href) return null;
        var m = String(href).match(/(?:https?:\/\/(?:www\.)?(?:x|twitter)\.com)?\/([A-Za-z0-9_]+)\/status\/(\d+)/);
        if (!m) return null;
        return {
          id: m[2],
          handle: m[1],
          url: 'https://x.com/' + m[1] + '/status/' + m[2]
        };
      }
      /** Profile handle from relative or absolute x.com href (not /status, not /i/). */
      function handleFromHref(href) {
        if (!href) return null;
        var m = String(href).match(/^(?:https?:\/\/(?:www\.)?(?:x|twitter)\.com)?\/([A-Za-z0-9_]+)\/?(?:\?.*)?$/i);
        if (!m) return null;
        var h = m[1];
        if (/^(i|home|explore|search|notifications|messages|settings|compose|intent|share|hashtag)$/i.test(h)) {
          return null;
        }
        return h;
      }
      function pickStatus(scope) {
        if (!scope) return null;
        var links = scope.querySelectorAll('a[href*="/status/"], [href*="/status/"]');
        var fallback = null;
        for (var j = 0; j < links.length; j++) {
          var href = links[j].getAttribute('href') || '';
          if (/\/(analytics|photo|video|likes)(\/|$)/.test(href)) {
            if (!fallback) fallback = statusFromHref(href);
            continue;
          }
          var st = statusFromHref(href);
          if (st) return st;
        }
        return fallback;
      }
      /**
       * Nested quote card root: div[role=link] with User-Name + (tweetText|time),
       * not wrapping another article.
       */
      function findQuoteRoot(article) {
        var roleLinks = article.querySelectorAll('div[role="link"]');
        for (var i = 0; i < roleLinks.length; i++) {
          var el = roleLinks[i];
          if (!el.querySelector('[data-testid="User-Name"]')) continue;
          if (!el.querySelector('[data-testid="tweetText"]') && !el.querySelector('time')) continue;
          if (el.querySelector('article[data-testid="tweet"]')) continue;
          return el;
        }
        return null;
      }
      function isInside(node, root) {
        if (!node || !root) return false;
        if (root.contains) return root.contains(node);
        var p = node;
        while (p) {
          if (p === root) return true;
          p = p.parentElement;
        }
        return false;
      }
      /**
       * Collect /status/ URLs from React fiber/props. Quote cards are often
       * div[role=link] with no <a href>; the destination lives in props.
       */
      function statusCandidatesFromReact(el) {
        var out = [];
        var seenIds = {};
        if (!el) return out;
        var seen = typeof WeakSet !== 'undefined' ? new WeakSet() : null;
        function add(href) {
          var st = statusFromHref(href);
          if (!st || seenIds[st.id]) return;
          seenIds[st.id] = true;
          out.push(st);
        }
        function walk(node, depth) {
          if (!node || depth > 18 || out.length > 12) return;
          if (typeof node === 'string') { add(node); return; }
          if (typeof node !== 'object') return;
          if (node.nodeType) return; // skip DOM nodes
          if (seen) {
            try { if (seen.has(node)) return; seen.add(node); } catch (e) { return; }
          }
          try {
            if (typeof node.href === 'string') add(node.href);
          } catch (e) {}
          try {
            for (var k in node) {
              if (!Object.prototype.hasOwnProperty.call(node, k)) continue;
              if (k === 'stateNode' || k === '_owner' || k === 'containerInfo') continue;
              try { walk(node[k], depth + 1); } catch (e) {}
            }
          } catch (e) {}
        }
        var propKeys = Object.keys(el);
        for (var i = 0; i < propKeys.length; i++) {
          var key = propKeys[i];
          if (key.indexOf('__reactFiber') !== 0 &&
              key.indexOf('__reactProps') !== 0 &&
              key.indexOf('__reactInternalInstance') !== 0) continue;
          try { walk(el[key], 0); } catch (e) {}
        }
        return out;
      }
      /** Recover quote status id/url when the card has no clean status <a>. */
      function recoverQuoteStatus(quoteRoot, article, primaryId, quoteHandle) {
        var st = pickStatus(quoteRoot);
        if (st) return st;
        var time = quoteRoot.querySelector('time');
        if (time) {
          var a = time.closest && time.closest('a[href]');
          if (a) {
            st = statusFromHref(a.getAttribute('href'));
            if (st) return st;
          }
          var p = time.parentElement;
          while (p && p !== quoteRoot) {
            if (p.tagName === 'A') {
              st = statusFromHref(p.getAttribute('href'));
              if (st) return st;
            }
            p = p.parentElement;
          }
        }
        var cands = statusCandidatesFromReact(quoteRoot);
        // Also scan a couple of parents — props sometimes live one level up.
        var par = quoteRoot.parentElement;
        for (var d = 0; d < 2 && par && par !== article; d++) {
          var more = statusCandidatesFromReact(par);
          for (var m = 0; m < more.length; m++) cands.push(more[m]);
          par = par.parentElement;
        }
        var preferred = null;
        var fallback = null;
        for (var c = 0; c < cands.length; c++) {
          var cand = cands[c];
          if (primaryId && cand.id === primaryId) continue;
          if (!fallback) fallback = cand;
          if (quoteHandle && cand.handle &&
              cand.handle.toLowerCase() === String(quoteHandle).toLowerCase()) {
            preferred = cand;
            break;
          }
        }
        st = preferred || fallback;
        if (st) return st;
        var attrs = quoteRoot.attributes || [];
        for (var i = 0; i < attrs.length; i++) {
          st = statusFromHref(attrs[i].value);
          if (st) return st;
        }
        return null;
      }
      function parseUserBlock(userName) {
        var author = null;
        var handle = null;
        if (!userName) return { author: author, handle: handle };
        var raw = visibleText(userName);
        var lines = raw.split('\n').map(function(s) { return s.trim(); }).filter(Boolean);
        if (lines.length) author = lines[0];
        var hm = raw.match(/@([A-Za-z0-9_]+)/);
        if (hm) handle = hm[1];
        if (!handle) {
          var userLinks = userName.querySelectorAll('a[href]');
          for (var k = 0; k < userLinks.length; k++) {
            var uh = handleFromHref(userLinks[k].getAttribute('href') || '');
            if (uh) { handle = uh; break; }
          }
        }
        return { author: author, handle: handle };
      }
      /**
       * Locale-independent ad flag. Same signal as hideAds: cells with
       * *-impression-pixel (placementTracking alone also wraps some organic
       * video tweets — do NOT use that alone).
       */
      function detectAd(article) {
        var cell = article.closest('[data-testid="cellInnerDiv"]') ||
          article.closest('[data-testid="placementTracking"]') ||
          article.parentElement;
        if (!cell) return false;
        return !!cell.querySelector('[data-testid$="-impression-pixel"]');
      }
      /**
       * Retweet socialContext: locale-independent via retweet SVG path near
       * socialContext; name/handle from the context node when present.
       * Handle comes from socialContext (or nearby) link href — absolute or relative.
       */
      function detectRetweetedBy(article) {
        var social = article.querySelector('[data-testid="socialContext"]');
        if (!social) return null;
        var row = social;
        var hasRtIcon = false;
        for (var d = 0; d < 6 && row; d++) {
          var paths = row.querySelectorAll ? row.querySelectorAll('svg path') : [];
          for (var p = 0; p < paths.length; p++) {
            var dd = paths[p].getAttribute('d') || '';
            if (dd.indexOf('M4.75 3.79') === 0 || dd.indexOf('M4.5 3.88') === 0) {
              hasRtIcon = true;
              break;
            }
          }
          if (hasRtIcon) break;
          row = row.parentElement;
        }
        var socialRaw = visibleText(social);
        var wordingRt = /retweeted|reposted|poda[łl](a)? dalej|hat retweetet|ha retwitteado|a retweeté|retweetou|リツイート/i.test(socialRaw);
        if (!hasRtIcon && !wordingRt) return null;
        var name = null;
        var handle = null;
        var nameSpan = social.querySelector('span[dir="ltr"] span') ||
          social.querySelector('span[dir="ltr"]');
        if (nameSpan) name = visibleText(nameSpan);
        if (!name) {
          var cleaned = socialRaw
            .replace(/^(Użytkownik|User)\s+/i, '')
            .replace(/\s+(poda[łl]a?\s+dalej|retweeted|reposted|hat retweetet|ha retwitteado|a retweeté|retweetou).*$/i, '')
            .trim();
          if (cleaned) name = cleaned;
        }
        function takeHandleFrom(root) {
          if (!root) return null;
          // socialContext is often a bare <span>; the profile <a> wraps it.
          if (root.tagName === 'A') {
            var selfH = handleFromHref(root.getAttribute('href') || '');
            if (selfH) return { handle: selfH, link: root };
          }
          var links = root.querySelectorAll('a[href]');
          for (var i = 0; i < links.length; i++) {
            var h = handleFromHref(links[i].getAttribute('href') || '');
            if (h) return { handle: h, link: links[i] };
          }
          return null;
        }
        var hit = takeHandleFrom(social);
        if (!hit) {
          var anc = social.parentElement;
          for (var ad = 0; ad < 6 && anc; ad++) {
            hit = takeHandleFrom(anc);
            if (hit) break;
            anc = anc.parentElement;
          }
        }
        if (hit) {
          handle = hit.handle;
          if (!name) name = visibleText(hit.link) || null;
        }
        if (!name && !handle) return null;
        var out = {};
        if (name) out.name = name;
        if (handle) out.handle = handle;
        return out;
      }
      /** Quote tweet card: nested div[role=link] with its own User-Name + text. */
      function detectQuoted(article, primaryId) {
        var quoteRoot = findQuoteRoot(article);
        if (!quoteRoot) return null;
        var userName = quoteRoot.querySelector('[data-testid="User-Name"]');
        var parsed = parseUserBlock(userName);
        if (!parsed.handle) {
          var av = quoteRoot.querySelector('[data-testid^="UserAvatar-Container-"]');
          if (av) {
            var am = (av.getAttribute('data-testid') || '').match(/^UserAvatar-Container-(.+)$/);
            if (am) parsed.handle = am[1];
          }
        }
        var textEl = quoteRoot.querySelector('[data-testid="tweetText"]');
        var qText = textEl ? visibleText(textEl) : '';
        var st = recoverQuoteStatus(quoteRoot, article, primaryId, parsed.handle);
        var q = {
          handle: parsed.handle || (st && st.handle) || null,
          id: st ? st.id : null,
          url: st ? st.url : null,
          text: qText
        };
        if (!q.handle && !q.text && !q.id) return null;
        return q;
      }
      function detectMedia(article, quoteRoot) {
        var media = [];
        var seen = {};
        function add(type) {
          if (seen[type]) return;
          seen[type] = true;
          media.push({ type: type });
        }
        var nodes = article.querySelectorAll(
          '[data-testid="tweetPhoto"],[data-testid="videoComponent"],[data-testid="videoPlayer"],[data-testid="card.wrapper"]'
        );
        for (var i = 0; i < nodes.length; i++) {
          var node = nodes[i];
          if (quoteRoot && isInside(node, quoteRoot)) continue;
          var tid = node.getAttribute('data-testid') || '';
          if (tid === 'tweetPhoto') add('photo');
          else if (tid === 'videoComponent' || tid === 'videoPlayer') add('video');
          else if (tid === 'card.wrapper') add('card');
        }
        return media;
      }
      var tweets = [];
      var articles = document.querySelectorAll('article[data-testid="tweet"]');
      for (var i = 0; i < articles.length; i++) {
        var article = articles[i];
        var quoteRoot = findQuoteRoot(article);
        var st = pickStatus(article);
        // Prefer primary status not inside the quote nest.
        if (quoteRoot) {
          var links = article.querySelectorAll('a[href*="/status/"]');
          var primarySt = null;
          var fallback = null;
          for (var j = 0; j < links.length; j++) {
            if (isInside(links[j], quoteRoot)) continue;
            var href = links[j].getAttribute('href') || '';
            if (/\/(analytics|photo|video|likes)(\/|$)/.test(href)) {
              if (!fallback) fallback = statusFromHref(href);
              continue;
            }
            var pst = statusFromHref(href);
            if (pst) { primarySt = pst; break; }
          }
          st = primarySt || fallback || st;
        }
        var id = st ? st.id : null;
        var url = st ? st.url : null;
        var author = null;
        var handle = null;
        var userNames = article.querySelectorAll('[data-testid="User-Name"]');
        var primaryUser = null;
        for (var u = 0; u < userNames.length; u++) {
          if (quoteRoot && isInside(userNames[u], quoteRoot)) continue;
          primaryUser = userNames[u];
          break;
        }
        if (!primaryUser && userNames.length) primaryUser = userNames[0];
        var parsedUser = parseUserBlock(primaryUser);
        author = parsedUser.author;
        handle = parsedUser.handle;
        var text = '';
        var textEls = article.querySelectorAll('[data-testid="tweetText"]');
        for (var t = 0; t < textEls.length; t++) {
          if (quoteRoot && isInside(textEls[t], quoteRoot)) continue;
          text = visibleText(textEls[t]);
          break;
        }
        var timeEl = null;
        var times = article.querySelectorAll('time');
        for (var ti = 0; ti < times.length; ti++) {
          if (quoteRoot && isInside(times[ti], quoteRoot)) continue;
          timeEl = times[ti];
          break;
        }
        var time = null;
        if (timeEl) {
          time = timeEl.getAttribute('datetime') || (timeEl.textContent || null);
        }
        var isAd = detectAd(article);
        var retweetedBy = detectRetweetedBy(article);
        var quoted = detectQuoted(article, id);
        var media = detectMedia(article, quoteRoot);
        var card = {
          id: id,
          author: author,
          handle: handle,
          text: text,
          time: time,
          url: url
        };
        if (isAd) card.isAd = true;
        if (retweetedBy) card.retweetedBy = retweetedBy;
        if (quoted) card.quoted = quoted;
        if (media.length) card.media = media;
        tweets.push(card);
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
