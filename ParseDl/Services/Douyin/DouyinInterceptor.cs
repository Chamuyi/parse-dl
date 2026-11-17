namespace ParseDl.Services.Douyin;

/// <summary>
/// 注入到抖音页面的拦截脚本（对齐 Flutter 版 lib/services/douyin_interceptor_js.dart）。
///
/// 思路：不自行计算平台接口签名，而是**搭页面自己的车** —— 页面算好签名、发完请求、
/// 拿回完整 JSON，我们只在 XHR/fetch 的出口把响应体抄一份。签名怎么变都不用跟着改。
///
/// 两个关键设计：
///   1. **回传完整变体**而不是挑好的一条地址 —— 一条视频会下发多个 bit_rate
///      （不同分辨率/编码）+ 多个镜像，「下载源 / 质量优先策略」就是在这堆候选里挑；
///      挑的动作必须放在**下载时**（C# 侧），否则改了清晰度设置已抓到的条目不会跟着变。
///   2. **认不认一条作品看页面 DOM 而不是接口** —— 响应先进缓存，只有页面真把它
///      渲染成卡片（href / data-e2e-aweme-id / 元素 id 里带作品 id）才算识别，
///      顺手描一圈黄框。于是「列表里的」「页面上黄着的」是同一批。
///
/// 用法：<c>CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(DouyinInterceptor.Script)</c>
/// —— 注册一次即对之后所有文档生效（含 SPA 内部跳转后的新文档）。
///
/// 注意：postMessage 传的是**对象**而不是 JSON.stringify 后的字符串，
/// C# 侧用 <c>TryGetWebMessageAsString</c> 取到的就是那段 JSON。
/// </summary>
public static class DouyinInterceptor
{
    public static string Script => ScriptBody;

    private const string ScriptBody = """
(function () {
  'use strict';
  if (window.__PD_DY_HOOKED) { return; }
  window.__PD_DY_HOOKED = true;

  var MAX_QUEUE = 400;
  var MAX_SEEN = 8000;
  var MAX_PER_RESPONSE = 300;
  var MAX_DEPTH = 9;
  var MAX_BODY = 8 * 1024 * 1024;
  var MAX_CACHE = 2000;
  var FLUSH_MS = 120;
  var SCAN_MS = 400;
  var TICK_MS = 900;

  // 端点白名单：逐端点注册，一个端点对一类内容，不靠通配。
  var WATCH_RULES = [
    { re: /^\/aweme\/v1\/web\/follow\/feed\/*$/,                      kind: 'feed' },
    { re: /^\/aweme\/v1\/web\/tab\/feed\/*$/,                         kind: 'feed' },
    { re: /^\/aweme\/v1\/web\/module\/feed\/*$/,                      kind: 'feed' },
    { re: /^\/aweme\/v2\/web\/module\/feed\/*$/,                      kind: 'feed' },
    { re: /^\/aweme\/v1\/web\/familiar\/recommend\/feed\/*$/,        kind: 'feed' },
    { re: /^\/aweme\/v1\/web\/aweme\/(post|favorite|listcollection)\/*$/, kind: 'profile' },
    { re: /^\/aweme\/v1\/web\/collects\/video\/list\/*$/,            kind: 'profile' },
    { re: /^\/aweme\/v1\/web\/aweme\/detail\/*$/,                     kind: 'detail' },
    { re: /^\/aweme\/v1\/web\/collects\/list\/*$/,                    kind: 'list' },
    { re: /^\/aweme\/v1\/web\/(mix|series)\/aweme\/*$/,               kind: 'list' },
    { re: /^\/aweme\/v1\/web\/music\/listcollection\/*$/,             kind: 'list' },
    { re: /^\/aweme\/v1\/web\/douyin\/select\/tab\/course\/catagory\/video\/*$/, kind: 'list' },
    { re: /^\/aweme\/v1\/web\/comment\/list\/*$/,                     kind: 'comment' }
  ];

  function watchKindOf(url) {
    if (!url || typeof url !== 'string') { return null; }
    var p;
    try {
      p = url.indexOf('://') >= 0 ? new URL(url).pathname : url.split('?')[0];
    } catch (e) { return null; }
    for (var i = 0; i < WATCH_RULES.length; i++) {
      if (WATCH_RULES[i].re.test(p)) { return WATCH_RULES[i].kind; }
    }
    return null;
  }

  var kindCount = Object.create(null);
  var seen = Object.create(null);
  var seenCount = 0;
  var captured = 0;
  var queue = [];
  var queueLen = 0;
  var timer = null;
  var bridgeRetry = 0;

  // 接口缓存与页面对齐：接口响应先进缓存，只有页面真渲染成卡片的才算识别。
  var cache = Object.create(null);
  var cacheOrder = [];
  var cacheSize = 0;
  var reported = Object.create(null);
  var identified = 0;
  var marked = 0;
  var renderedIds = 0;
  var MARK_ATTR = 'data-has-marked';

  function put(it) {
    if (cache[it.id] || reported[it.id]) { return; }
    cache[it.id] = it;
    cacheOrder.push(it);
    cacheSize++;
    if (cacheSize > MAX_CACHE) {
      var old = cacheOrder.shift();
      if (old) { delete cache[old.id]; cacheSize--; }
    }
  }

  function idOfHref(href) {
    if (!href || typeof href !== 'string') { return ''; }
    var q = href.indexOf('?');
    var p = q >= 0 ? href.slice(0, q) : href;
    if (p.charAt(p.length - 1) === '/') { p = p.slice(0, -1); }
    var s = p.slice(p.lastIndexOf('/') + 1);
    return /^\d{15,25}$/.test(s) ? s : '';
  }

  function idFromLocation() {
    try {
      var m = /^\/(?:video|note)\/(\d{15,25})/.exec(location.pathname);
      if (m) { return m[1]; }
      var p = new URL(location.href).searchParams;
      return p.get('modal_id') || p.get('aweme_id') || '';
    } catch (e) { return ''; }
  }

  function scanDom() {
    var dom = {
      ids: Object.create(null),
      nodes: Object.create(null),
      order: [],
      from: { href: 0, e2e: 0, attr: 0, url: 0 },
      attrSample: [],
      noData: []
    };
    function take(id, el, how) {
      if (!id || dom.ids[id]) { return; }
      dom.ids[id] = 1;
      dom.nodes[id] = el || null;
      dom.order.push(id);
      dom.from[how]++;
      if (how === 'attr' && dom.attrSample.length < 3 && el) {
        dom.attrSample.push(
          (el.tagName || '?') + '#' + String(el.id || '').slice(0, 44) +
          '.' + String(typeof el.className === 'string' ? el.className : '').slice(0, 30));
      }
    }
    try {
      var els = document.querySelectorAll('a[href], [data-e2e-aweme-id], [id]');
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        var aid = el.getAttribute('data-e2e-aweme-id') || '';
        if (aid && /^\d{15,25}$/.test(aid)) { take(aid, el, 'e2e'); continue; }
        var hid = idOfHref(el.href);
        if (hid) { take(hid, el, 'href'); continue; }
        var m = /(^|\D)(\d{15,25})(?=\D|$)/.exec(el.id || '');
        var cid = m && m[2];
        if (!cid) { continue; }
        if (cache[cid]) { take(cid, el, 'attr'); }
        else if (dom.noData.length < 6) { dom.noData.push(cid); }
      }
      var loc = idFromLocation();
      if (loc && !dom.ids[loc]) { take(loc, null, 'url'); }
    } catch (e) {}
    renderedIds = dom.order.length;
    return dom;
  }

  function markNode(el) {
    if (!el || el.getAttribute(MARK_ATTR)) { return; }
    try {
      el.setAttribute(MARK_ATTR, '1');
      el.style.border = '2px solid #ffb600';
      el.style.transition = 'all .2s';
      el.style.borderRadius = '12px';
      el.style.overflow = 'hidden';
      marked++;
    } catch (e) {}
  }

  function reconcile() {
    scanTimer = null;
    if (!cacheSize) { return; }
    var dom = scanDom();
    if (!dom.order.length) { return; }
    var fresh = [];
    for (var i = 0; i < dom.order.length; i++) {
      var id = dom.order[i];
      var it = cache[id];
      if (!it) { continue; }
      markNode(dom.nodes[id]);
      if (reported[id]) { continue; }
      reported[id] = 1;
      identified++;
      fresh.push(it);
    }
    for (var j = 0; j < fresh.length; j++) { push(fresh[j]); }
  }

  var scanTimer = null;
  function scheduleScan(ms) {
    if (scanTimer) { clearTimeout(scanTimer); }
    scanTimer = setTimeout(reconcile, ms || SCAN_MS);
  }

  var episodeMap = Object.create(null);

  function bridge() {
    try {
      if (window.chrome && window.chrome.webview &&
          typeof window.chrome.webview.postMessage === 'function') {
        return window.chrome.webview;
      }
    } catch (e) {}
    return null;
  }

  function flush() {
    timer = null;
    if (!queueLen) { return; }
    var b = bridge();
    if (!b) {
      if (bridgeRetry++ < 150) { timer = setTimeout(flush, 200); }
      return;
    }
    bridgeRetry = 0;
    var batch = queue;
    queue = [];
    queueLen = 0;
    try {
      b.postMessage({ __pd: 'douyin', items: batch });
    } catch (e) {
      queue = batch.concat(queue);
      queueLen = queue.length;
      if (!timer) { timer = setTimeout(flush, FLUSH_MS); }
    }
  }

  function push(item) {
    queue.push(item);
    queueLen++;
    if (queueLen >= MAX_QUEUE) { flush(); return; }
    if (!timer) { timer = setTimeout(flush, FLUSH_MS); }
  }

  // ── 字段拾取小工具 ────────────────────────────────────────
  function str() {
    for (var i = 0; i < arguments.length; i++) {
      var v = arguments[i];
      if (typeof v === 'string' && v) { return v; }
      if (typeof v === 'number' && isFinite(v)) { return String(v); }
    }
    return '';
  }

  function num() {
    for (var i = 0; i < arguments.length; i++) {
      var v = Number(arguments[i]);
      if (isFinite(v) && v > 0) { return v; }
    }
    return 0;
  }

  function https(u) {
    if (!u) { return ''; }
    if (u.indexOf('//') === 0) { return 'https:' + u; }
    return u.replace(/^http:/, 'https:');
  }

  function collectUrls(addr) {
    var out = [];
    if (!addr) { return out; }
    var list = addr.url_list || addr.urlList || [];
    for (var i = 0; i < list.length; i++) {
      var u = https(list[i]);
      if (u && out.indexOf(u) < 0) { out.push(u); }
    }
    return out;
  }

  function bitRateVariants(v) {
    var out = [];
    if (!v) { return out; }
    var br = v.bit_rate || v.bitRate || [];
    for (var i = 0; i < br.length; i++) {
      var e = br[i];
      if (!e) { continue; }
      var pa = e.play_addr || e.playAddr || {};
      var urls = collectUrls(pa);
      if (!urls.length) { continue; }
      out.push({
        urls: urls,
        kind: 'bit_rate',
        w: num(pa.width),
        h: num(pa.height),
        fps: num(e.FPS, e.fps),
        br: num(e.bit_rate, e.bitRate),
        size: num(pa.data_size, pa.dataSize),
        format: str(e.format, pa.format, v.format),
        gear: str(e.gear_name, e.gearName),
        bytevc1: e.is_bytevc1 === true || e.isBytevc1 === true
      });
    }
    return out;
  }

  function addrVariant(v, field, kind) {
    if (!v) { return null; }
    var a = v[field];
    var urls = collectUrls(a);
    if (!urls.length) { return null; }
    return {
      urls: urls,
      kind: kind,
      w: num(a.width),
      h: num(a.height),
      fps: num(v.FPS, v.fps),
      br: 0,
      size: num(a.data_size, a.dataSize),
      format: str(a.format, v.format),
      gear: '',
      bytevc1: false
    };
  }

  function videoVariants(v) {
    var out = bitRateVariants(v);
    var direct = [
      addrVariant(v, 'play_addr', 'default'),
      addrVariant(v, 'play_addr_h264', 'h264'),
      addrVariant(v, 'play_addr_265', 'h265'),
      addrVariant(v, 'download_addr', 'download')
    ];
    for (var i = 0; i < direct.length; i++) {
      if (direct[i]) { out.push(direct[i]); }
    }
    return out;
  }

  function imageEntries(imgs) {
    var out = [];
    if (!imgs || !imgs.length) { return out; }
    for (var i = 0; i < imgs.length; i++) {
      var im = imgs[i];
      if (!im) { continue; }
      var dis = im.display_image || im.displayImage || {};
      var urls = [];
      var push = function (u) {
        u = https(u);
        if (u && urls.indexOf(u) < 0) { urls.push(u); }
      };
      var primary = im.url_list || im.urlList || [];
      for (var a = 0; a < primary.length; a++) { push(primary[a]); }
      var extra = im.download_url_list || dis.download_url_list ||
                  dis.url_list || [];
      for (var b = 0; b < extra.length; b++) { push(extra[b]); }

      var live = [];
      if (im.video) {
        live = videoVariants(im.video);
        if (!live.length) {
          var only = addrVariant(im.video, 'play_addr', 'default');
          if (only) { live = [only]; }
        }
      }
      if (!urls.length && !live.length) { continue; }
      out.push({ urls: urls, live: live });
    }
    return out;
  }

  function coverOf(v, pics) {
    if (v) {
      var c = v.cover || v.origin_cover || v.dynamic_cover || {};
      var cl = c.url_list || [];
      if (cl.length) { return https(cl[0]); }
    }
    if (pics && pics.length && pics[0].urls && pics[0].urls.length) {
      return pics[0].urls[0];
    }
    return '';
  }

  function episodeOf(a) {
    var st = a.stats || {};
    var n = num(st.current_episode, st.currentEpisode);
    if (n > 0) { return n; }
    var id = str(a.aweme_id, a.awemeId, a.group_id, a.item_id);
    var mapped = id ? Number(episodeMap[id]) : 0;
    return isFinite(mapped) && mapped > 0 ? mapped : 0;
  }

  // 把一条 aweme 压成瘦对象（字段名单见 C# 侧 DouyinPayloadParser）。
  function normalize(a) {
    var id = str(a.aweme_id, a.awemeId, a.group_id, a.item_id);
    if (!id) { return null; }

    var v = a.video || null;
    var ipi = a.image_post_info || a.imagePostInfo || null;
    var imgs = a.images || (ipi && ipi.images) || null;

    var videos = videoVariants(v);
    var pics = imageEntries(imgs);

    var hasVideo = false;
    for (var i = 0; i < videos.length; i++) {
      if (videos[i].kind === 'bit_rate' || videos[i].kind === 'default') {
        hasVideo = true;
        break;
      }
    }
    var hasPics = false;
    for (var j = 0; j < pics.length; j++) {
      if (pics[j].urls.length) { hasPics = true; break; }
    }

    var kind = '';
    if (hasPics && hasVideo) { kind = 'mixed'; }
    else if (hasPics) { kind = 'images'; }
    else if (videos.length) { kind = 'video'; }
    if (!kind) { return null; }

    var tags = [];
    var te = a.text_extra || a.textExtra || [];
    for (var k = 0; k < te.length; k++) {
      var h = te[k] && (te[k].hashtag_name || te[k].hashtagName);
      if (h && tags.indexOf(h) < 0) { tags.push(h); }
    }

    var au = a.author || {};
    var auUid = au.uid || au.sec_uid || '';
    var mu = a.music || {};
    var st = a.statistics || {};

    return {
      id: id,
      kind: kind,
      desc: str(a.desc, a.item_title, a.preview_title, id),
      createTime: num(a.create_time, a.createTime),
      durationMs: v ? num(v.duration) : 0,
      ratio: v ? str(v.ratio) : '',
      authorUid: str(auUid),
      authorName: str(au.nickname, au.unique_id, au.short_id),
      authorId: str(au.unique_id, au.short_id, au.uid),
      cover: coverOf(v, pics),
      videos: videos,
      images: pics,
      tags: tags,
      musicTitle: str(mu.title),
      musicAuthor: str(mu.author),
      musicMid: str(mu.mid),
      musicUrls: collectUrls(mu.play_url || mu.playUrl),
      digg: num(st.digg_count, st.diggCount),
      comment: num(st.comment_count, st.commentCount),
      collect: num(st.collect_count, st.collectCount),
      share: num(st.share_count, st.shareCount),
      episode: episodeOf(a)
    };
  }

  function looksLikeAweme(o) {
    if (!o || typeof o !== 'object' || Array.isArray(o)) { return false; }
    var id = o.aweme_id;
    if (typeof id !== 'string' && typeof id !== 'number') { return false; }
    return o.video !== undefined || o.images !== undefined ||
           o.image_post_info !== undefined;
  }

  function harvestEpisodes(node, depth) {
    if (!node || typeof node !== 'object' || depth > 5) { return; }
    if (Array.isArray(node)) {
      for (var i = 0; i < node.length; i++) { harvestEpisodes(node[i], depth + 1); }
      return;
    }
    var m = node.item_id_to_episode || node.itemIdToEpisode;
    if (m && typeof m === 'object') {
      for (var k in m) {
        if (!(k in episodeMap) && m[k]) { episodeMap[k] = m[k]; }
      }
    }
    for (var key in node) {
      if (Object.prototype.hasOwnProperty.call(node, key) && node[key] &&
          typeof node[key] === 'object') {
        harvestEpisodes(node[key], depth + 1);
      }
    }
  }

  function scan(node, out, depth) {
    if (!node || depth > MAX_DEPTH || out.length >= MAX_PER_RESPONSE) { return; }
    if (Array.isArray(node)) {
      for (var i = 0; i < node.length; i++) {
        scan(node[i], out, depth + 1);
        if (out.length >= MAX_PER_RESPONSE) { return; }
      }
      return;
    }
    if (typeof node !== 'object') { return; }
    if (looksLikeAweme(node)) {
      var item = normalize(node);
      if (item) { out.push(item); }
      return;
    }
    for (var k in node) {
      if (Object.prototype.hasOwnProperty.call(node, k)) {
        scan(node[k], out, depth + 1);
        if (out.length >= MAX_PER_RESPONSE) { return; }
      }
    }
  }

  function handle(url, data) {
    var kind = watchKindOf(url);
    if (!kind) { return; }
    collect(kind, data);
  }

  function collect(kind, data) {
    var list = [];
    try {
      harvestEpisodes(data, 0);
      scan(data, list, 0);
    } catch (e) { return; }
    if (!list.length) { return; }
    for (var i = 0; i < list.length; i++) {
      var it = list[i];
      if (seen[it.id]) { continue; }
      if (seenCount >= MAX_SEEN) {
        seen = Object.create(null);
        seenCount = 0;
      }
      seen[it.id] = 1;
      seenCount++;
      captured++;
      kindCount[kind] = (kindCount[kind] || 0) + 1;
      put(it);
    }
    scheduleScan(SCAN_MS);
  }

  var pathTally = Object.create(null);
  var pathKeys = 0;
  function notePath(url) {
    try {
      var p = url.indexOf('://') >= 0 ? new URL(url).pathname : url.split('?')[0];
      if (!/^\/aweme\/v\d\/web\//.test(p)) { return; }
      if (pathTally[p]) { pathTally[p]++; return; }
      if (pathKeys >= 40) { return; }
      pathTally[p] = 1;
      pathKeys++;
    } catch (e) {}
  }

  function shouldWatch(url) {
    notePath(url);
    return watchKindOf(url) !== null;
  }

  // ── 首屏 SSR 数据 ─────────────────────────────────────────
  var ssrDone = false;
  function harvestSsr() {
    if (ssrDone) { return; }
    ssrDone = true;
    var used = 0;
    try {
      var list = document.getElementsByTagName('script');
      for (var i = 0; i < list.length && used < 8; i++) {
        var t = list[i].textContent || '';
        if (t.length > 6 * 1024 * 1024 || t.indexOf('aweme_id') < 0) { continue; }
        var data = looseJson(t);
        if (!data) { continue; }
        used++;
        collect('ssr', data);
      }
    } catch (e) {}
    scheduleScan(0);
  }

  function tryParse(t) {
    if (!t) { return null; }
    var c = t.charAt(0);
    if (c !== '{' && c !== '[') { return null; }
    try { return JSON.parse(t); } catch (e) { return null; }
  }

  function looseJson(text) {
    var s = text.replace(/^[\s\uFEFF]+/, '');
    var obj = tryParse(s);
    if (obj) { return obj; }
    var eq = s.indexOf('=');
    if (eq > 0 && eq < 200) {
      obj = tryParse(s.slice(eq + 1).replace(/;[\s\S]*$/, '').replace(/^[\s\uFEFF]+/, ''));
      if (obj) { return obj; }
    }
    if (s.indexOf('%7B') === 0 || s.indexOf('%22aweme_id%22') > 0) {
      try { obj = tryParse(decodeURIComponent(s)); } catch (e) { obj = null; }
      if (obj) { return obj; }
    }
    var a = s.indexOf('{'), b = s.lastIndexOf('}');
    if (a >= 0 && b > a) { return tryParse(s.slice(a, b + 1)); }
    return null;
  }

  try {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', function () { setTimeout(harvestSsr, 0); });
    } else {
      setTimeout(harvestSsr, 0);
    }
    window.addEventListener('load', function () { setTimeout(harvestSsr, 0); });
  } catch (e) {}

  try {
    setInterval(function () { scheduleScan(0); }, TICK_MS);
    var scrollTimer = null;
    var onScroll = function () {
      if (scrollTimer) { return; }
      scrollTimer = setTimeout(function () {
        scrollTimer = null;
        scheduleScan(0);
      }, 200);
    };
    window.addEventListener('scroll', onScroll, true);
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden) { scheduleScan(0); }
    });
  } catch (e) {}

  function parseText(txt) {
    if (!txt || txt.length > MAX_BODY) { return null; }
    var s = txt.charCodeAt(0);
    if (s !== 123 && s !== 91) { return null; }
    try { return JSON.parse(txt); } catch (e) { return null; }
  }

  try {
    var XO = XMLHttpRequest.prototype.open;
    var XS = XMLHttpRequest.prototype.send;

    XMLHttpRequest.prototype.open = function (method, url) {
      try { this.__pdUrl = String(url == null ? '' : url); } catch (e) {}
      return XO.apply(this, arguments);
    };

    XMLHttpRequest.prototype.send = function () {
      try {
        var self = this;
        var url = self.__pdUrl || '';
        if (shouldWatch(url)) {
          self.addEventListener('load', function () {
            try {
              var rt = self.responseType;
              if (rt === 'json') {
                if (self.response) { handle(url, self.response); }
                return;
              }
              if (rt === '' || rt === 'text') { handle(url, parseText(self.responseText)); }
            } catch (e) {}
          });
        }
      } catch (e) {}
      return XS.apply(this, arguments);
    };
  } catch (e) {}

  try {
    if (typeof window.fetch === 'function') {
      var OF = window.fetch;
      window.fetch = function (input, init) {
        var url = '';
        try {
          url = typeof input === 'string' ? input : (input && input.url) || '';
        } catch (e) {}
        var p = OF.apply(this, arguments);
        try {
          if (shouldWatch(url) && p && typeof p.then === 'function') {
            p.then(function (resp) {
              try {
                if (!resp || !resp.clone) { return; }
                resp.clone().text().then(function (t) {
                  handle(url, parseText(t));
                }).catch(function () {});
              } catch (e) {}
            }).catch(function () {});
          }
        } catch (e) {}
        return p;
      };
    }
  } catch (e) {}

  function domCensus() {
    var c = {
      path: '', nodes: 0, cache: cacheSize, hit: 0,
      from: { href: 0, e2e: 0, attr: 0, url: 0 },
      attrSample: [], noData: [], endpoints: pathTally,
      byCache: { video: 0, images: 0, mixed: 0 },
      byHit: { video: 0, images: 0, mixed: 0 },
      byMark: { video: 0, images: 0, mixed: 0 },
      markedTotal: marked
    };
    try {
      c.path = location.pathname;
      c.nodes = document.querySelectorAll('a[href], [data-e2e-aweme-id], [id]').length;
      for (var i = 0; i < cacheOrder.length; i++) {
        var it = cacheOrder[i];
        if (it && c.byCache.hasOwnProperty(it.kind)) { c.byCache[it.kind]++; }
      }
      var dom = scanDom();
      c.from = dom.from;
      c.attrSample = dom.attrSample;
      c.noData = dom.noData;
      c.hit = dom.order.length;
      for (var j = 0; j < dom.order.length; j++) {
        var m = cache[dom.order[j]];
        if (!m || !c.byHit.hasOwnProperty(m.kind)) { continue; }
        c.byHit[m.kind]++;
        var el = dom.nodes[dom.order[j]];
        if (el && el.getAttribute(MARK_ATTR)) { c.byMark[m.kind]++; }
      }
    } catch (e) { c.err = String(e); }
    return c;
  }

  // ── 诊断：直接从页面内嵌数据里抽当前作品（作品详情页不发 XHR，只能读内嵌）
  // 抖音单页应用把首屏数据塞在 <script id="RENDER_DATA"> 或 window._ROUTER_DATA 里。
  // 这里把它整段吐出来，交给 C# 侧落盘分析。
  window.__pdPageData = function () {
    try {
      var out = { found: false, source: '', raw: '' };
      var el = document.getElementById('RENDER_DATA');
      if (el && el.textContent && el.textContent.length > 200) {
        out.found = true; out.source = 'RENDER_DATA';
        out.raw = decodeURIComponent(el.textContent);
        return JSON.stringify(out);
      }
      if (window._ROUTER_DATA) {
        out.found = true; out.source = '_ROUTER_DATA';
        out.raw = JSON.stringify(window._ROUTER_DATA);
        return JSON.stringify(out);
      }
      // 兜底：把整个 document 里的 script 里最长的 JSON 片段挑出来
      var scripts = document.querySelectorAll('script');
      var best = '';
      for (var i = 0; i < scripts.length; i++) {
        var s = scripts[i].textContent || '';
        if (s.length > best.length && s.indexOf('aweme') >= 0) { best = s; }
      }
      if (best.length > 200) {
        out.found = true; out.source = 'script'; out.raw = best;
      }
      return JSON.stringify(out);
    } catch (e) {
      return JSON.stringify({ found: false, source: 'error', raw: String(e) });
    }
  };
  window.__pdDouyinInfo = function () {
    var eps = 0;
    for (var k in episodeMap) { eps++; }
    return {
      hooked: true,
      captured: captured,
      identified: identified,
      marked: marked,
      cached: cacheSize,
      rendered: renderedIds,
      pending: queueLen,
      episodes: eps,
      kinds: kindCount,
      dom: domCensus()
    };
  };
})();
""";
}
