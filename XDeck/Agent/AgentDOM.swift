import Foundation

/// Maintained JS helpers injected via `evaluateJavaScript` for the agent bridge.
/// Prefer these over ad-hoc agent CSS — x.com `data-testid` still churns.
enum AgentDOM {
    /// Parse visible tweet cards in the column WebView.
    /// Emits isAd, retweetedBy, quoted, media, metrics, article, inReplyTo,
    /// isPinned when present. Status URLs are normalized (never `/analytics`).
    /// Ad detection: impression pixels + status-page fallbacks (no `<time>` +
    /// placement / Ad|Promoted|Promowane label).
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
      /**
       * Locale-independent engagement counts from aria-labels / button text.
       * Handles 1.2K, 1,2 tys., 3 tys, 1.5M, 2 mln, plain ints with spaces/commas.
       */
      function parseCount(raw) {
        if (raw == null) return null;
        var s = String(raw).replace(/\u00a0/g, ' ').trim();
        if (!s) return null;
        var withUnit = s.match(/([\d]+(?:[.,]\d+)?)\s*(tys\.?|k|mln\.?|m|b)\b/i);
        if (withUnit) {
          var n = parseFloat(withUnit[1].replace(',', '.'));
          if (isNaN(n)) return null;
          var unit = withUnit[2].toLowerCase().replace(/\./g, '');
          if (unit === 'tys' || unit === 'k') n *= 1000;
          else if (unit === 'mln' || unit === 'm') n *= 1e6;
          else if (unit === 'b') n *= 1e9;
          return Math.round(n);
        }
        var m = s.match(/(\d{1,3}(?:[ \u00a0.,]\d{3})+|\d+)/);
        if (!m) return null;
        var cleaned = m[1].replace(/[ \u00a0]/g, '');
        // 1,234 (US) or 1.234 (EU thousands) → int; keep single decimal aside
        if (/^\d{1,3}(,\d{3})+$/.test(cleaned)) cleaned = cleaned.replace(/,/g, '');
        else if (/^\d{1,3}(\.\d{3})+$/.test(cleaned)) cleaned = cleaned.replace(/\./g, '');
        else cleaned = cleaned.replace(/,/g, '');
        var n2 = parseInt(cleaned, 10);
        return isNaN(n2) ? null : n2;
      }
      function countFromControl(el) {
        if (!el) return null;
        var aria = el.getAttribute('aria-label') || '';
        var n = parseCount(aria);
        if (n != null) return n;
        var spans = el.querySelectorAll('span');
        for (var i = 0; i < spans.length; i++) {
          var t = visibleText(spans[i]);
          if (!t || !/[\d]/.test(t)) continue;
          if (/reply|repost|retweet|like|bookmark|view|odpowiedz|podaj|polub|zakład|wyświet/i.test(t) &&
              t.length > 12) continue;
          n = parseCount(t);
          if (n != null) return n;
        }
        return parseCount(visibleText(el));
      }
      function detectMetrics(article) {
        // Always emit the five keys; unknown (control missing or no count in
        // aria/label) is JSON null — never invent 0 for hidden bookmark counts.
        var metrics = {
          replies: null,
          reposts: null,
          likes: null,
          views: null,
          bookmarks: null
        };
        function setKey(key, el) {
          if (!el) return;
          var n = countFromControl(el);
          metrics[key] = n != null ? n : null;
        }
        setKey('replies', article.querySelector('[data-testid="reply"]'));
        setKey('reposts', article.querySelector('[data-testid="retweet"]'));
        setKey('likes', article.querySelector('[data-testid="like"]') ||
          article.querySelector('[data-testid="unlike"]'));
        setKey('bookmarks', article.querySelector('[data-testid="bookmark"]') ||
          article.querySelector('[data-testid="removeBookmark"]'));
        var analytics = article.querySelector('a[href*="/analytics"]');
        if (analytics) {
          var v = countFromControl(analytics);
          metrics.views = v != null ? v : null;
        }
        if (metrics.views == null) {
          // Some builds put view count on a role=link without /analytics yet.
          var candidates = article.querySelectorAll('a[aria-label], div[aria-label], span[aria-label]');
          for (var i = 0; i < candidates.length; i++) {
            var lab = candidates[i].getAttribute('aria-label') || '';
            if (!/view|wyświet/i.test(lab)) continue;
            if (/analytics|post analytics|statystyk/i.test(lab) || /view/i.test(lab)) {
              var vv = parseCount(lab);
              if (vv != null) { metrics.views = vv; break; }
            }
          }
        }
        var any = false;
        for (var k in metrics) {
          if (metrics[k] != null) { any = true; break; }
        }
        return any ? metrics : null;
      }
      /** X Article signal: exact Article/Artykuł badge and/or /i/article/ link. */
      function hasArticleLabel(article) {
        if (article.querySelector('a[href*="/i/article/"]')) return true;
        var card = article.querySelector('[data-testid="card.wrapper"]');
        var scopes = card ? [card] : [];
        scopes.push(article);
        for (var s = 0; s < scopes.length; s++) {
          var scan = scopes[s].querySelectorAll('span, div, a');
          for (var i = 0; i < scan.length && i < 80; i++) {
            var el = scan[i];
            // Prefer leaf-ish nodes (no nested element text duplication)
            if (el.children && el.children.length > 2) continue;
            var t = visibleText(el);
            if (!t) continue;
            if (/^(Artykuł|Article)$/i.test(t)) return true;
          }
          if (card && s === 0) {
            // Label sometimes sits just above the card
            var prev = card.parentElement;
            for (var up = 0; up < 3 && prev; up++) {
              var sibs = prev.querySelectorAll('span');
              for (var j = 0; j < sibs.length && j < 20; j++) {
                if (/^(Artykuł|Article)$/i.test(visibleText(sibs[j]))) return true;
              }
              prev = prev.parentElement;
            }
          }
        }
        return false;
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
       * Locale-independent ad flag. Primary: *-impression-pixel (same as hideAds).
       * Fallback for status/conversation pages where impression pixels miss
       * promoted cards: no <time> + placementTracking, or Ad/Promoted label.
       */
      function detectAd(article) {
        var cell = article.closest('[data-testid="cellInnerDiv"]') ||
          article.closest('[data-testid="placementTracking"]') ||
          article.parentElement;
        if (cell && cell.querySelector('[data-testid$="-impression-pixel"]')) return true;
        var hasTime = !!article.querySelector('time');
        var hasPlacement = !!(article.closest('[data-testid="placementTracking"]') ||
          (cell && cell.querySelector('[data-testid="placementTracking"]')));
        if (!hasTime && hasPlacement) return true;
        var labelNodes = article.querySelectorAll('span, div, [dir="ltr"]');
        for (var i = 0; i < labelNodes.length && i < 40; i++) {
          var t = visibleText(labelNodes[i]);
          if (!t || t.length > 24) continue;
          if (/^(Ad|Ads|Promoted|Promowane|Reklama|Sponsored)$/i.test(t)) return true;
        }
        if (cell) {
          var near = cell.querySelectorAll('span');
          for (var j = 0; j < near.length && j < 30; j++) {
            var nt = visibleText(near[j]);
            if (/^(Ad|Ads|Promoted|Promowane|Reklama|Sponsored)$/i.test(nt)) return true;
          }
        }
        return false;
      }
      /** Reply context: "Replying to @x" / "W odpowiedzi do @x". */
      function detectInReplyTo(article) {
        var handles = [];
        var seen = {};
        function add(h) {
          if (!h || seen[h.toLowerCase()]) return;
          seen[h.toLowerCase()] = true;
          handles.push(h);
        }
        var nodes = article.querySelectorAll('div, span, a');
        for (var i = 0; i < nodes.length && i < 80; i++) {
          var t = visibleText(nodes[i]);
          if (!t || t.length > 120) continue;
          if (!/(?:Replying to|W odpowiedzi do)/i.test(t)) continue;
          var re = /@([A-Za-z0-9_]+)/g;
          var m;
          while ((m = re.exec(t))) add(m[1]);
          var links = nodes[i].querySelectorAll('a[href]');
          for (var k = 0; k < links.length; k++) {
            var hh = handleFromHref(links[k].getAttribute('href') || '');
            if (hh) add(hh);
          }
          break;
        }
        if (!handles.length) return null;
        return { handle: handles[0], handles: handles.length > 1 ? handles : undefined };
      }
      /** Pinned tweet marker on profile timelines. */
      function detectPinned(article) {
        var social = article.querySelector('[data-testid="socialContext"]');
        if (social && /pinned|przypięt/i.test(visibleText(social))) return true;
        var cell = article.closest('[data-testid="cellInnerDiv"]') || article.parentElement;
        if (!cell) return false;
        var spans = cell.querySelectorAll('span');
        for (var i = 0; i < spans.length && i < 20; i++) {
          var t = visibleText(spans[i]);
          if (/^Pinned(\s+Tweet)?$/i.test(t) || /^Przypięt[yae]/i.test(t)) return true;
        }
        return false;
      }
      /**
       * X Articles: long-form cards labeled Article/Artykuł with title/preview
       * and often empty tweetText. Title/preview MUST come from the article
       * card element only — never author header or tweetText.
       */
      function detectArticle(article) {
        if (!hasArticleLabel(article)) return null;
        // X Articles today: data-testid=article-cover-image (+ Artykuł/Article badge).
        // Older link cards: card.wrapper. Never use author header / tweetText.
        var cover = article.querySelector('[data-testid="article-cover-image"]');
        var card = article.querySelector('[data-testid="card.wrapper"]');
        var detail = card && (
          card.querySelector('[data-testid="card.layoutLarge.detail"]') ||
          card.querySelector('[data-testid="card.layoutSmall.detail"]') ||
          card.querySelector('[data-testid="card.layoutLarge"]') ||
          card.querySelector('[data-testid="card.layoutSmall"]')
        );
        var scope = detail || card;
        var tweetTextElEarly = article.querySelector('[data-testid="tweetText"]');
        var userNameEarly = article.querySelector('[data-testid="User-Name"]');
        if (!scope && cover) {
          // Walk up from cover until badge + title are visible — stop before
          // swallowing tweetText / User-Name (that caused author/tweet-as-title).
          scope = cover;
          for (var d = 0; d < 6 && scope && scope.parentElement; d++) {
            var par = scope.parentElement;
            if (tweetTextElEarly && par.contains(tweetTextElEarly)) break;
            if (userNameEarly && par.contains(userNameEarly)) break;
            var pt = visibleText(par);
            if (pt && /(?:Artykuł|Article)/i.test(pt) && pt.length > 20 && pt.length < 900) {
              scope = par;
              // Prefer the smallest container that has a non-badge line
              var plines = pt.split('\n').map(function(s) { return s.trim(); }).filter(Boolean)
                .filter(function(s) { return !/^(Artykuł|Article)$/i.test(s); });
              if (plines.length >= 1) break;
            } else {
              scope = par;
            }
          }
        }
        if (!scope) {
          var articleLink = article.querySelector('a[href*="/i/article/"]');
          if (articleLink) {
            scope = articleLink.closest('[data-testid="card.wrapper"]') || articleLink.parentElement;
          }
        }
        if (!scope) return null;
        var tweetTextEl = article.querySelector('[data-testid="tweetText"]');
        var userNameEls = article.querySelectorAll('[data-testid="User-Name"]');
        function excluded(node) {
          if (!node) return true;
          if (tweetTextEl && (tweetTextEl === node || tweetTextEl.contains(node))) return true;
          for (var u = 0; u < userNameEls.length; u++) {
            if (userNameEls[u] === node || userNameEls[u].contains(node)) return true;
          }
          if (!(scope === node || scope.contains(node))) return true;
          return false;
        }
        function cleanArticleLine(t) {
          if (!t) return '';
          t = String(t).replace(/^(Artykuł|Article)\s*/i, '').trim();
          if (/^(Artykuł|Article)$/i.test(t)) return '';
          return t;
        }
        /** Title = heading element only; preview = next block (never glued heading+body). */
        var title = null;
        var preview = null;
        var titleEl = null;
        // 1) Explicit heading
        var heading = scope.querySelector('[role="heading"], h1, h2, h3');
        if (heading && !excluded(heading)) {
          var ht = cleanArticleLine(visibleText(heading));
          if (ht && ht.length >= 4 && ht.length < 150) {
            title = ht;
            titleEl = heading;
          }
        }
        // 2) First leaf-ish block after badge/cover with length < 150
        if (!title) {
          var nodes = scope.querySelectorAll('span, div, a, p, h1, h2, h3');
          for (var j = 0; j < nodes.length; j++) {
            var el = nodes[j];
            if (excluded(el)) continue;
            var tid = el.getAttribute('data-testid') || '';
            if (tid === 'article-cover-image') continue;
            var ct = cleanArticleLine(visibleText(el));
            if (!ct || ct.length < 8) continue;
            // Skip containers that glue heading+body into one string (>149)
            // — descend into children instead.
            if (ct.length >= 150) {
              var split = [];
              for (var c = 0; c < el.children.length; c++) {
                var ch = el.children[c];
                if (excluded(ch)) continue;
                var cht = cleanArticleLine(visibleText(ch));
                if (cht && cht.length >= 4) split.push({ el: ch, text: cht });
              }
              if (split.length >= 1 && split[0].text.length < 150) {
                title = split[0].text;
                titleEl = split[0].el;
                if (split.length >= 2) preview = split[1].text;
                break;
              }
              continue;
            }
            // Leaf-ish: don't pick a wrapper whose only job is nesting
            if (el.children && el.children.length > 2) {
              var onlyBadge = true;
              for (var k = 0; k < el.children.length; k++) {
                var kt = cleanArticleLine(visibleText(el.children[k]));
                if (kt && kt.length >= 8 && kt !== ct) { onlyBadge = false; break; }
              }
              if (!onlyBadge && el.children.length > 2) continue;
            }
            title = ct;
            titleEl = el;
            break;
          }
        }
        // 3) Preview = next distinct block after the heading element
        if (title && !preview && titleEl) {
          var sib = titleEl.nextElementSibling;
          while (sib) {
            if (!excluded(sib)) {
              var st = cleanArticleLine(visibleText(sib));
              if (st && st !== title && st.length >= 4) { preview = st; break; }
            }
            sib = sib.nextElementSibling;
          }
          if (!preview) {
            // Walk parent’s next children after titleEl
            var par = titleEl.parentElement;
            while (!preview && par && scope.contains(par)) {
              var after = false;
              for (var s = 0; s < par.children.length; s++) {
                var kid = par.children[s];
                if (kid === titleEl || kid.contains(titleEl)) { after = true; continue; }
                if (!after) continue;
                if (excluded(kid)) continue;
                var pt2 = cleanArticleLine(visibleText(kid));
                if (pt2 && pt2 !== title && pt2.length >= 4) { preview = pt2; break; }
              }
              if (preview) break;
              if (par === scope) break;
              par = par.parentElement;
            }
          }
        }
        // Guard: reject glued titles (heading+body without separator)
        if (title && title.length >= 150) {
          title = null;
          preview = null;
        }
        if (title) {
          for (var u2 = 0; u2 < userNameEls.length; u2++) {
            var un = visibleText(userNameEls[u2]);
            if (un && (title === un || un.indexOf(title) === 0 || title.indexOf(un.split('\n')[0]) === 0)) {
              title = null; preview = null; break;
            }
          }
        }
        var out = {};
        if (title) out.title = title;
        if (preview) out.preview = preview;
        return Object.keys(out).length ? out : null;
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
        // N5: quoted X Articles often have empty tweetText — fill quoted.article
        // the same way as top-level cards (title/preview from article card).
        var qArticle = detectArticle(quoteRoot);
        var q = {
          handle: parsed.handle || (st && st.handle) || null,
          id: st ? st.id : null,
          url: st ? st.url : null,
          text: qText
        };
        if (qArticle) q.article = qArticle;
        if (!q.handle && !q.text && !q.id && !q.article) return null;
        return q;
      }
      function detectMedia(article, quoteRoot, hasArticle) {
        var media = [];
        var seen = {};
        function add(type) {
          if (seen[type]) return;
          seen[type] = true;
          media.push({ type: type });
        }
        if (hasArticle || article.querySelector('[data-testid="article-cover-image"]')) {
          add('article');
        }
        var nodes = article.querySelectorAll(
          '[data-testid="tweetPhoto"],[data-testid="videoComponent"],[data-testid="videoPlayer"],[data-testid="card.wrapper"],[data-testid="article-cover-image"]'
        );
        for (var i = 0; i < nodes.length; i++) {
          var node = nodes[i];
          if (quoteRoot && isInside(node, quoteRoot)) continue;
          var tid = node.getAttribute('data-testid') || '';
          if (tid === 'tweetPhoto') add('photo');
          else if (tid === 'videoComponent' || tid === 'videoPlayer') add('video');
          else if (tid === 'article-cover-image') add('article');
          else if (tid === 'card.wrapper' && !hasArticle) add('card');
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
        var articleMeta = detectArticle(article);
        var media = detectMedia(article, quoteRoot, !!articleMeta);
        var metrics = detectMetrics(article);
        var inReplyTo = detectInReplyTo(article);
        var isPinned = detectPinned(article);
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
        if (metrics) card.metrics = metrics;
        if (articleMeta) card.article = articleMeta;
        if (inReplyTo) {
          card.inReplyTo = inReplyTo.handles
            ? { handle: inReplyTo.handle, handles: inReplyTo.handles }
            : { handle: inReplyTo.handle };
        }
        if (isPinned) card.isPinned = true;
        tweets.push(card);
      }
      return tweets;
    })()
    """#

    /// Typed notification events when the column is on `/notifications`.
    /// Likes/follows/reposts of own posts often lack tweet cards — only chrome text.
    static let extractNotificationsJS = #"""
    (function() {
      var path = String(location.pathname || '');
      if (!/\/notifications/i.test(path)) return [];
      function visibleText(el) {
        if (!el) return '';
        return (document.visibilityState === 'hidden'
          ? (el.textContent || '')
          : (el.innerText || el.textContent || '')).trim();
      }
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
      /**
       * N1: Derive type from notification *cell chrome*, not tweet action buttons.
       * Reply/mention cells embed a full tweet article (whose retweet/like SVGs
       * must not classify the cell as repost/like). Repost/like/follow cells
       * show a type icon in the header outside that article.
       */
      function classifyType(cell, raw) {
        var lower = (raw || '').toLowerCase();
        var article = cell.querySelector('article[data-testid="tweet"]');
        function iconTypeOutsideArticle() {
          var paths = cell.querySelectorAll('svg path');
          for (var i = 0; i < paths.length; i++) {
            var pathEl = paths[i];
            if (article && article.contains(pathEl)) continue;
            // Also skip action-bar buttons if somehow outside article
            var btn = pathEl.closest && pathEl.closest(
              '[data-testid="reply"],[data-testid="retweet"],[data-testid="like"],[data-testid="unlike"],[data-testid="bookmark"],[data-testid="share"]'
            );
            if (btn) continue;
            var d = pathEl.getAttribute('d') || '';
            // Heart (like)
            if (d.indexOf('M20.884') === 0 || d.indexOf('M16.697') === 0 ||
                d.indexOf('M12 21.638') === 0) return 'like';
            // Repost arrows
            if (d.indexOf('M4.75 3.79') === 0 || d.indexOf('M4.5 3.88') === 0) return 'repost';
            // Person/follow
            if (d.indexOf('M17.863') === 0 || d.indexOf('M10 4c-1.105') === 0 ||
                d.indexOf('M12.225') === 0) return 'follow';
          }
          return null;
        }
        var chromeIcon = iconTypeOutsideArticle();
        // Aggregation chrome wins when present (like/repost/follow of your posts).
        if (chromeIcon) return chromeIcon;
        if (/liked|polubił|polubiła|polubili|gefällt|aimé|dio like/i.test(lower)) return 'like';
        if (/reposted|retweeted|poda[łl](a|i)?\s+dalej|hat retweetet|retweeteó/i.test(lower)) return 'repost';
        if (/followed|obserwuje|obserwują|folgt|suivi|empezó a seguir/i.test(lower)) return 'follow';
        if (/replied|odpowiedzia[łl]|répond|respondió/i.test(lower)) return 'reply';
        if (/mention|wspomnia[łl]|mentioned|mencion/i.test(lower)) return 'mention';
        // Full tweet article without aggregation chrome → reply or mention.
        if (article) {
          // inReplyTo / reply context on the embedded tweet → reply
          var replyCtx = article.querySelector('[data-testid="socialContext"]');
          var articleText = visibleText(article).toLowerCase();
          if (replyCtx || /repli(?:ed|y)|odpowied|respond/i.test(articleText) ||
              /replying to|w odpowiedzi|in reply to/i.test(articleText)) {
            return 'reply';
          }
          return 'mention';
        }
        return 'other';
      }
      function actorsFrom(cell) {
        var actors = [];
        var seen = {};
        function add(name, handle) {
          var key = (handle || name || '').toLowerCase();
          if (!key || seen[key]) return;
          seen[key] = true;
          var a = {};
          if (name) a.name = name;
          if (handle) a.handle = handle;
          actors.push(a);
        }
        var avatars = cell.querySelectorAll('[data-testid^="UserAvatar-Container-"]');
        for (var i = 0; i < avatars.length; i++) {
          var tid = avatars[i].getAttribute('data-testid') || '';
          var am = tid.match(/^UserAvatar-Container-(.+)$/);
          if (am && am[1] && am[1] !== 'unknown') add(null, am[1]);
        }
        var userNames = cell.querySelectorAll('[data-testid="User-Name"]');
        for (var u = 0; u < userNames.length; u++) {
          var raw = visibleText(userNames[u]);
          var name = raw.split('\n').map(function(s) { return s.trim(); }).filter(Boolean)[0] || null;
          var hm = raw.match(/@([A-Za-z0-9_]+)/);
          var handle = hm ? hm[1] : null;
          if (!handle) {
            var links = userNames[u].querySelectorAll('a[href]');
            for (var k = 0; k < links.length; k++) {
              handle = handleFromHref(links[k].getAttribute('href') || '');
              if (handle) break;
            }
          }
          add(name, handle);
        }
        // Notification header often: "Alice and Bob liked your post"
        if (!actors.length) {
          var links2 = cell.querySelectorAll('a[href]');
          for (var L = 0; L < links2.length; L++) {
            var h = handleFromHref(links2[L].getAttribute('href') || '');
            if (h) add(visibleText(links2[L]) || null, h);
          }
        }
        return actors;
      }
      function actorCountFrom(raw, actorsLen) {
        var m = (raw || '').match(/(\d+)\s+(?:others|innych|weitere|autres|otros)/i);
        if (m) return actorsLen + parseInt(m[1], 10);
        if (/ and | i | und | et | y /i.test(raw || '') && actorsLen >= 1) {
          // "A and B" → at least 2
          return Math.max(actorsLen, 2);
        }
        return actorsLen;
      }
      /**
       * N2: React status recovery must stay inside this cell.
       * Never walk fiber.return / sibling / alternate — that inherits a
       * neighbour notification's status id (e.g. every like → a neighbour post id).
       */
      function statusCandidatesFromReact(el) {
        var out = [];
        var seenIds = {};
        if (!el) return out;
        var seen = typeof WeakSet !== 'undefined' ? new WeakSet() : null;
        var skipKeys = {
          stateNode: 1, _owner: 1, containerInfo: 1,
          return: 1, sibling: 1, alternate: 1, _debugOwner: 1,
          dependencies: 1, lanes: 1, nextEffect: 1, firstEffect: 1,
          lastEffect: 1, updateQueue: 1, queue: 1, lanesLane: 1,
          childLanes: 1, memoizedState: 1
        };
        function add(href) {
          var st = statusFromHref(href);
          if (!st || seenIds[st.id]) return;
          seenIds[st.id] = true;
          out.push(st);
        }
        function walk(node, depth) {
          if (!node || depth > 12 || out.length > 6) return;
          if (typeof node === 'string') { add(node); return; }
          if (typeof node !== 'object') return;
          if (node.nodeType) return;
          if (seen) {
            try { if (seen.has(node)) return; seen.add(node); } catch (e) { return; }
          }
          try {
            if (typeof node.href === 'string') add(node.href);
            if (typeof node.url === 'string') add(node.url);
            if (node.id != null && node.user && (node.user.screen_name || node.user.screenName)) {
              add('https://x.com/' + (node.user.screen_name || node.user.screenName) +
                '/status/' + String(node.id));
            }
            if (node.rest_id != null && (node.screen_name || node.user_screen_name)) {
              add('https://x.com/' + (node.screen_name || node.user_screen_name) +
                '/status/' + String(node.rest_id));
            }
          } catch (e) {}
          try {
            // Prefer props bags over climbing the fiber tree.
            if (node.memoizedProps) walk(node.memoizedProps, depth + 1);
            if (node.pendingProps) walk(node.pendingProps, depth + 1);
            // Descend into this fiber's child subtree only (not siblings/parents).
            if (node.child) walk(node.child, depth + 1);
            for (var k in node) {
              if (!Object.prototype.hasOwnProperty.call(node, k)) continue;
              if (skipKeys[k]) continue;
              if (k === 'memoizedProps' || k === 'pendingProps' || k === 'child') continue;
              // Avoid walking DOM nodes / arrays of sibling fibers
              if (k === 'children' && node.child) continue;
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
          try {
            var root = el[key];
            // For fibers: only props + descendant child chain.
            if (root && typeof root === 'object' && (root.memoizedProps || root.pendingProps || root.tag != null)) {
              if (root.memoizedProps) walk(root.memoizedProps, 0);
              if (root.pendingProps) walk(root.pendingProps, 0);
              if (root.child) walk(root.child, 0);
            } else {
              walk(root, 0);
            }
          } catch (e) {}
        }
        return out;
      }
      function targetFrom(cell) {
        var article = cell.querySelector('article[data-testid="tweet"]');
        var scope = article || cell;
        var st = null;
        function acceptStatus(href, el) {
          if (!href) return null;
          if (/\/(analytics|photo|video|likes)(\/|$)/.test(href)) return null;
          // N2: never accept a status link that is not inside this notification cell.
          if (el && !cell.contains(el)) return null;
          return statusFromHref(href);
        }
        // 1) Clean status <a> links scoped to the cell (skip analytics/photo/…)
        var links = scope.querySelectorAll('a[href*="/status/"], [href*="/status/"]');
        for (var i = 0; i < links.length; i++) {
          if (!cell.contains(links[i])) continue;
          st = acceptStatus(links[i].getAttribute('href') || '', links[i]);
          if (st) break;
        }
        // 2) time → closest anchor *inside the cell*
        if (!st) {
          var timeEl = scope.querySelector('time');
          if (timeEl && cell.contains(timeEl)) {
            var a = timeEl.closest && timeEl.closest('a[href]');
            if (a && cell.contains(a)) st = acceptStatus(a.getAttribute('href') || '', a);
            var p = timeEl.parentElement;
            while (!st && p && cell.contains(p) && p !== cell) {
              if (p.tagName === 'A') st = acceptStatus(p.getAttribute('href') || '', p);
              p = p.parentElement;
            }
          }
        }
        // 3) any href attr on the cell only
        if (!st) {
          var anyHref = cell.querySelectorAll('[href*="/status/"]');
          for (var h = 0; h < anyHref.length; h++) {
            if (!cell.contains(anyHref[h])) continue;
            st = acceptStatus(anyHref[h].getAttribute('href') || '', anyHref[h]);
            if (st) break;
          }
        }
        var text = '';
        var textEl = scope.querySelector('[data-testid="tweetText"]');
        if (textEl && cell.contains(textEl)) text = visibleText(textEl);
        // 4) React props on *this cell's* nodes only. If nothing in-cell → null id
        // (prefer missing over a neighbour post id).
        if (!st && text) {
          var cands = statusCandidatesFromReact(scope);
          if (!cands.length && scope !== cell) cands = statusCandidatesFromReact(cell);
          // Prefer a single unambiguous candidate; multiple ids often mean fiber bleed.
          if (cands.length === 1) st = cands[0];
        }
        if (!st && !text) return null;
        var out = {};
        if (st) { out.id = st.id; out.url = st.url; }
        if (text) out.text = text;
        return out;
      }
      var events = [];
      var cells = document.querySelectorAll('[data-testid="cellInnerDiv"]');
      for (var i = 0; i < cells.length; i++) {
        var cell = cells[i];
        // Skip pure composer / empty chrome
        var raw = visibleText(cell);
        if (!raw || raw.length < 2) continue;
        // Skip tab row
        if (/^(All|Mentions|Verified|Wszystkie|Wzmianki)/i.test(raw) && raw.length < 40) continue;
        var type = classifyType(cell, raw);
        var actors = actorsFrom(cell);
        // Skip timeline tweets that are just "Following" organic without notif chrome
        if (type === 'other' && !actors.length && !cell.querySelector('[data-testid="socialContext"]') &&
            cell.querySelector('article[data-testid="tweet"]')) {
          // Still emit as mention-ish when on notifications tab
          type = 'other';
        }
        var timeEl = cell.querySelector('time');
        var time = timeEl
          ? (timeEl.getAttribute('datetime') || (timeEl.textContent || null))
          : null;
        var target = targetFrom(cell);
        var actorCount = actorCountFrom(raw, actors.length);
        var ev = {
          type: type,
          actors: actors,
          actorCount: actorCount || actors.length
        };
        if (target) ev.target = target;
        if (time) ev.time = time;
        // Drop empty noise
        if (!actors.length && !target && type === 'other') continue;
        events.push(ev);
      }
      return events;
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

    /// Visible page text with script/style/noscript/template stripped.
    /// When `visibilityState=hidden`, `innerText` is empty — fall back to a
    /// clone with non-content tags removed so we never dump `__INITIAL_STATE__`.
    static func innerTextJS(maxChars: Int) -> String {
        """
        (function() {
          var body = document.body;
          if (!body) return '';
          function readableText(root) {
            if (!root) return '';
            try {
              var clone = root.cloneNode(true);
              var kill = clone.querySelectorAll('script,style,noscript,template');
              for (var i = 0; i < kill.length; i++) {
                var n = kill[i];
                if (n && n.parentNode) n.parentNode.removeChild(n);
              }
              // Prefer innerText on the clone (layout-ish); fall back to textContent.
              var t = (clone.innerText || clone.textContent || '');
              return String(t).replace(/\\u00a0/g, ' ').trim();
            } catch (e) {
              return '';
            }
          }
          var t = '';
          if (document.visibilityState !== 'hidden') {
            t = (body.innerText || '').trim();
          }
          // Hidden WebView (or empty innerText): strip scripts then read.
          if (!t) t = readableText(body);
          if (t.length > \(maxChars)) t = t.slice(0, \(maxChars));
          return t;
        })()
        """
    }

    /// Per-column `document.visibilityState` for /health.
    static let visibilityStateJS = #"""
    (function() {
      return String(document.visibilityState || 'unknown');
    })()
    """#

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
      var reactHidden = false;
      try {
        var rr = document.getElementById('react-root');
        if (rr) {
          var rst = window.getComputedStyle(rr);
          reactHidden = rst.display === 'none' || rst.visibility === 'hidden';
        }
      } catch (e) {}
      // failedScript shells often keep stray chrome / CSS primary hints while
      // hiding #react-root — treat that as error even if primary looks true.
      var errorShell = reactHidden || (!tweets && !primary && (
        tryAgain ||
        (errCopy.length > 0 && /something went wrong|try again|javascript is disabled/i.test(errCopy)) ||
        /failedscript=/i.test(href) ||
        /something went wrong\.?\s*try again|javascript is disabled/i.test(lower)
      )) || (!tweets && errCopy.length > 0 && tryAgain &&
        /something went wrong|javascript is disabled/i.test(errCopy));
      var searchPage = /\/search/i.test(path);
      var statusPage = /\/[^/]+\/status\/\d+/i.test(path);
      var searchEmpty = searchPage && primary && tweets === 0 &&
        /no results|nie znaleziono|nothing matched|try searching for something else|brak wyników/i.test(lower);
      // N4: X not-found page ("Hmm…this page doesn’t exist") — settle immediately,
      // do not retry for ~54s. Distinct from mid-hydrate blank or Try-again shells.
      var statusNotFound = statusPage && tweets === 0 && (
        /hmm[.…]*.*this page doesn.?t exist|this page doesn.?t exist|page doesn.?t exist|doesn.?t exist.*try searching|ta strona nie istnieje|nie znaleziono (?:tej )?strony|strona nie istnieje/i.test(lower) ||
        (primary && /try searching for something else/i.test(lower) &&
          /doesn.?t exist|nie istnieje/i.test(lower))
      );
      // Only treat as settled-empty on explicit unavailable / not-found copy — never
      // "something went wrong" (too easy to false-positive mid-hydrate).
      var statusEmpty = statusNotFound || (statusPage && primary && tweets === 0 &&
        /this post (?:isn.?t|is not) available|this post is unavailable|post (?:is )?unavailable|post niedostępny|post doesn.?t exist|nie istnieje|can.?t find this post|nie można znaleźć/i.test(lower));
      var challenge = /\/i\/flow\/login|\/account\/access|arkose|funcaptcha/i.test(href) ||
        /verify you(?:'| a)?re (?:a )?human|confirm you(?:'| a)?re not a bot|complete the challenge/i.test(lower);
      // Search + status: only "ready" once tweets land (or documented empty) —
      // not mere primaryColumn (SPA chrome hydrates before cards).
      var ready = !errorShell && !challenge && (
        tweets > 0 || searchEmpty || statusEmpty || (!searchPage && !statusPage && primary)
      );
      return {
        ready: ready,
        errorShell: errorShell,
        challenge: challenge,
        searchPage: searchPage,
        statusPage: statusPage,
        searchEmpty: searchEmpty,
        statusEmpty: statusEmpty,
        statusNotFound: statusNotFound,
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
