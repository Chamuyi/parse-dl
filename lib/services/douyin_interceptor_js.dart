/// 注入到抖音页面的拦截脚本（MAIN world，document_start）。
///
/// **思路**：不去自行计算平台的接口签名参数，
/// 而是**搭页面自己的车** —— 页面已经算好签名、发完请求、
/// 拿回了完整 JSON，我们只在 XHR/fetch 的出口把响应体抄一份。
/// 这样签名怎么变都不用跟着改。
///
/// 注入脚本本身就在主世界（拦截与消费同一个世界），
/// 不需要跨世界转发 ——
/// 可以直接 `window.chrome.webview.postMessage` 回 Dart，所以只有这一段。
///
/// **回传的是「完整变体」而不是「挑好的一条地址」** —— 这是关键设计：
/// 抖音一条视频会下发多个 `bit_rate`（不同分辨率/编码）+ 多个镜像，
/// 而「下载源 / 质量优先策略」就是在这堆候选里挑。挑的动作必须放在
/// **下载时**（Dart 侧），否则用户改了清晰度设置，已经抓到的条目不会跟着变。
/// 所以这里把候选原样带出，由 `douyin_source.dart` 按当前设置解析。
///
/// **认不认一条作品，看的是页面 DOM 而不是接口** —— 这是关键设计，
/// 见下面「接口缓存与页面对齐」一节。
///
/// 用法：`controller.addScriptToExecuteOnDocumentCreated(kDouyinInterceptorJs)`
/// —— 注册一次即对之后**所有**文档生效（含 SPA 内部跳转后的新文档）。
library;

/// 注入脚本正文。
///
/// 注意几个**必须**的细节：
///   1. `postMessage` 传的是**对象**而不是 `JSON.stringify` 后的字符串 ——
///      原生侧用 `get_WebMessageAsJson` 取内容，传字符串会被再包一层引号，
///      Dart 那边 `jsonDecode` 出来就变成 `String` 而不是 `Map`。
///   2. 全流程 try/catch 包住，任何异常都不许冒泡 —— 拦截脚本把宿主页面
///      搞崩是会直接白屏的。
///   3. 用 `depth` / `out.length` 双限流做递归扫描，避免在超大响应体上炸栈。
///   4. **不改写地址**（不把 `playwm` 换 `play`、不把 `.webp` 换 `.jpeg`）：
///      `play_addr` 就是页面自身提供的那路源地址；图片的 jpg 优先交给 Dart 侧按
///      「重排镜像顺序」实现（改后缀有被 CDN 路径校验拦掉的风险）。
const String kDouyinInterceptorJs = r"""
(function () {
  'use strict';
  if (window.__PD_DY_HOOKED) { return; }
  window.__PD_DY_HOOKED = true;

  var MAX_QUEUE = 400;          // 攒到这么多就立刻 flush
  var MAX_SEEN = 8000;          // 去重表上限，超了就整体清空重来
  var MAX_PER_RESPONSE = 300;   // 单个响应最多取多少条
  var MAX_DEPTH = 9;            // 递归深度上限
  var MAX_BODY = 8 * 1024 * 1024;
  var MAX_CACHE = 2000;         // 本页接口缓存上限（无限滚动能一直涨）
  var FLUSH_MS = 120;
  var SCAN_MS = 400;            // 响应到达后等多久再看 DOM —— 给 React 渲染留时间
  var TICK_MS = 900;            // 定时重扫：卡片要滚动到才挂进 DOM

  // ── 端点白名单（逐条列出要监听的接口）──────────────────
  //
  // **为什么不再用前缀匹配**：之前是「URL 里含 /aweme/v1/web/ 就抄」，于是
  // 搜索、用户资料、播放统计、任务列表这些接口也一并进来，右侧列表里就混进了
  // 用户根本没在页面上见过的作品（2026-09-18 实测 125 项 / 66 条作品）。
  // 逐端点注册，一个端点对一类内容，不靠通配。
  //
  // re   = 匹配端点路径的正则（结尾的 \/*$ 容忍任意个尾部斜杠）；
  // kind = 这一类响应的归类，**只用于诊断计数**（认不认一条作品由 DOM 决定，
  //        见下面「接口缓存与页面对齐」）。分组只有五类：
  //        feed / profile / detail / list / comment。
  var WATCH_RULES = [
    { re: /^\/aweme\/v1\/web\/follow\/feed\/*$/,                      kind: 'feed' },
    { re: /^\/aweme\/v1\/web\/tab\/feed\/*$/,                         kind: 'feed' },
    { re: /^\/aweme\/v1\/web\/module\/feed\/*$/,                      kind: 'feed' },
    { re: /^\/aweme\/v2\/web\/module\/feed\/*$/,                      kind: 'feed' },
    { re: /^\/aweme\/v1\/web\/familiar\/recommend\/feed\/*$/,         kind: 'feed' },
    { re: /^\/aweme\/v1\/web\/aweme\/(post|favorite|listcollection)\/*$/, kind: 'profile' },
    { re: /^\/aweme\/v1\/web\/collects\/video\/list\/*$/,             kind: 'profile' },
    { re: /^\/aweme\/v1\/web\/aweme\/detail\/*$/,                     kind: 'detail' },
    { re: /^\/aweme\/v1\/web\/collects\/list\/*$/,                    kind: 'list' },
    { re: /^\/aweme\/v1\/web\/(mix|series)\/aweme\/*$/,               kind: 'list' },
    { re: /^\/aweme\/v1\/web\/music\/listcollection\/*$/,             kind: 'list' },
    { re: /^\/aweme\/v1\/web\/douyin\/select\/tab\/course\/catagory\/video\/*$/, kind: 'list' },
    // comment/list 也在监听之列。评论里引用的作品因此会进
    // 本页缓存，但**只有页面真把它渲染成卡片才算识别**（见 scanDom），
    // 所以正常情况下它不会污染列表。这一行是纯对齐，想去掉就删。
    { re: /^\/aweme\/v1\/web\/comment\/list\/*$/,                     kind: 'comment' }
  ];

  // 命中白名单返回它的 kind，否则 null。
  function watchKindOf(url) {
    if (!url || typeof url !== 'string') { return null; }
    var p;
    try {
      // 只拿 pathname 比对：白名单正则以 \/*$ 收尾，带上 query 就匹配不上了
      p = url.indexOf('://') >= 0 ? new URL(url).pathname : url.split('?')[0];
    } catch (e) { return null; }
    for (var i = 0; i < WATCH_RULES.length; i++) {
      if (WATCH_RULES[i].re.test(p)) { return WATCH_RULES[i].kind; }
    }
    return null;
  }

  // 各 kind 实际贡献了多少条，只用于诊断日志：抖音改版时一眼看出是哪个端点没了
  var kindCount = Object.create(null);

  var seen = Object.create(null);
  var seenCount = 0;
  var captured = 0;
  var queue = [];
  var queueLen = 0;
  var timer = null;
  var bridgeRetry = 0;

  // ── 接口缓存与页面对齐 ────────────────────────────────────────
  //
  // **这是「识别」行为的关键**。它不把接口响应直接倒进界面：
  // 响应先进缓存，然后拿 `document.querySelectorAll('a[href]')` 给每条
  // 找 `href` 以 `/<aweme_id>` 结尾的节点 —— **找不到的条目被 filter 掉，
  // 找到的顺手描一圈黄框**（参照实现里由两个渲染函数负责）。
  // 于是「列表里的」「页面上黄着的」是同一批：用户滚到哪儿、页面渲染出几张卡，
  // 就识别几条。
  //
  // 我们之前的做法是按来源类别滑窗保留 12/5 条，那是**猜**页面
  // 该有多少条。2026-09-19 真机日志证明猜不准：同一类页面一会儿截到 12、
  // 一会儿留到 108，而屏幕上只有 3~4 张卡。现在改由 DOM 说话。
  var cache = Object.create(null);      // aweme_id -> 归一化条目
  var cacheOrder = [];                  // 到货顺序（超上限时丢最老的）
  var cacheSize = 0;
  var reported = Object.create(null);   // 已回传过的 id —— 只回传增量
  var identified = 0;                   // 已判定「页面出现过」的条数
  var marked = 0;                       // 描了黄框的条数
  var renderedIds = 0;                  // 上一次扫描时页面上有几个作品

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

  // href 里的作品 id：取路径最后一段纯数字（`/video/7xxx`、`/note/7xxx`）。
  // 另一种写法是拿 id 去逐个匹配页面上的 href；这里反过来
  // 先把页面上的 href 全抠成表再和缓存对，省掉 O(条目数 × 链接数) 的双循环。
  function idOfHref(href) {
    if (!href || typeof href !== 'string') { return ''; }
    var q = href.indexOf('?');
    var p = q >= 0 ? href.slice(0, q) : href;
    if (p.charAt(p.length - 1) === '/') { p = p.slice(0, -1); }
    var s = p.slice(p.lastIndexOf('/') + 1);
    return /^\d{15,25}$/.test(s) ? s : '';
  }

  // 详情页 / 弹窗播放里作品 id 在地址上，不在卡片链接上
  function idFromLocation() {
    try {
      var m = /^\/(?:video|note)\/(\d{15,25})/.exec(location.pathname);
      if (m) { return m[1]; }
      var p = new URL(location.href).searchParams;
      return p.get('modal_id') || p.get('aweme_id') || '';
    } catch (e) { return ''; }
  }

  // 页面上**当前真实渲染出来**的作品。
  //
  // 返回 `order`（文档顺序的作品 id 数组）而不是只返回集合 —— 用户要求抓取
  // 列表"按页面加载顺序从上到下"，那就必须以 DOM 里的先后为准，不能按接口
  // 到货顺序。`querySelectorAll` 一次查询返回的节点本身就是文档顺序。
  //
  // 三种承载作品 id 的形状都要认（2026-09-19 真机普查）：
  //   a[href]                → 作者主页 / 合集
  //   [data-e2e-aweme-id]    → 竖屏信息流
  //   [id] 里嵌着作品 id     → **精选页 `/jingxuan` 只有这一种**：46 个 a[href]
  //                            里一个 id 都抠不出来，全靠这条认出了 20 张卡
  //                            （它要求 id 已在缓存里，所以不会误伤）
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
        // 卡片明明在屏幕上、id 也读得到，但接口从没见过它 —— 这就是"首屏
        // 数据不走 XHR"的症状（抖音服务端直接写进 HTML）。普查里记下来。
        else if (dom.noData.length < 6) { dom.noData.push(cid); }
      }
      var loc = idFromLocation();
      if (loc && !dom.ids[loc]) { take(loc, null, 'url'); }
    } catch (e) {}
    renderedIds = dom.order.length;
    return dom;
  }

  // 描黄框。本项目的样式：
  //   border:2px solid #ffb600;transition:all .2s;border-radius:12px;overflow:hidden;
  // 一处偏离：它用 `setAttribute('style', …)` **整条覆盖**行内样式，
  // 那会把卡片自己的 display / 尺寸一起冲掉；这里改成逐属性 set，视觉一样、
  // 不破版面。`data-has-marked` 幂等，重复扫描不会叠加。
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

  // 把「接口已到」∩「页面已渲染」的作品回传，并给对应卡片描框。
  //
  // 缓存**不按页面清空**：抖音是 SPA，切走再切回来卡片是全新挂载的节点，
  // 清掉缓存就再也认不回它们（黄框会消失、列表不再增长）。留着缓存、
  // 每次扫描对当前 DOM 重描一遍即可 —— `markNode` 按节点上的
  // `data-has-marked` 幂等，`reported` 保证同一条作品只回传一次，
  // Dart 侧还有一层按 id 去重。
  function reconcile() {
    scanTimer = null;
    if (!cacheSize) { return; }
    var dom = scanDom();
    if (!dom.order.length) { return; }
    var fresh = [];
    // 按**文档顺序**遍历，不是按接口到货顺序 —— 右侧列表要跟页面上从上到下
    // 的版面一致，抖音一次响应里 aweme_list 的顺序和卡片排布顺序并不总是一样。
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

  // 合集 / 短剧的「item_id → 第几集」映射。
  // 抖音在合集列表响应里下发 `item_id_to_episode`，而详情/单条响应里没有，
  // 所以先攒起来，后面 normalize 时补集数。
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
      // 桥还没挂上（极少见）：退避重试，最多 150 次约 30 秒
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
      // 发失败就退回队列，下一轮再试
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

  // 把一个 `{url_list:[...]}` 形状的地址对象里的 URL 收集成去重数组。
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

  // `bit_rate[]` → 变体数组。质量属性（fps / 码率 / 档位 / ByteVC1）挂在
  // **bit_rate 条目**上，像素尺寸挂在它的 `play_addr` 上 —— 两处都要取。
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

  // 直接字段（play_addr / play_addr_h264 / play_addr_265 / download_addr）→ 变体。
  // 这类变体没有码率信息，质量评分拿不到分，只在「指定源」模式下使用。
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

  // 图集：每张图给一份**镜像列表**（顺序保持抖音下发的原样，jpg 优先在
  // Dart 侧重排），以及实况图的配对视频变体。
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
      // `download_url_list` 通常是原图，作为后备镜像追加在后面
      var extra = im.download_url_list || dis.download_url_list ||
                  dis.url_list || [];
      for (var b = 0; b < extra.length; b++) { push(extra[b]); }

      var live = [];
      // 实况图 = 静态图 + 一段配对视频（共用同一序号后缀）
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

  // 集数：优先 `stats.current_episode`，否则查合集映射表。
  function episodeOf(a) {
    var st = a.stats || {};
    var n = num(st.current_episode, st.currentEpisode);
    if (n > 0) { return n; }
    var id = str(a.aweme_id, a.awemeId, a.group_id, a.item_id);
    var mapped = id ? Number(episodeMap[id]) : 0;
    return isFinite(mapped) && mapped > 0 ? mapped : 0;
  }

  // ── 把一条 aweme 压成 Dart 侧要好用的瘦对象 ───────────────
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
      // 只有带码率信息的才算是「这条作品是视频」
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
    var mu = a.music || {};
    var st = a.statistics || {};

    return {
      id: id,
      kind: kind,
      desc: str(a.desc, a.item_title, a.preview_title, id),
      createTime: num(a.create_time, a.createTime),
      durationMs: v ? num(v.duration) : 0,
      ratio: v ? str(v.ratio) : '',
      authorUid: str(au.uid, au.sec_uid),
      authorName: str(au.nickname, au.unique_id, au.short_id),
      authorId: str(au.unique_id, au.short_id, au.uid),
      cover: coverOf(v, pics),
      videos: videos,
      images: pics,
      tags: tags,
      // BGM（「仅音频」模式下就是用它）
      musicTitle: str(mu.title),
      musicAuthor: str(mu.author),
      musicMid: str(mu.mid),
      musicUrls: collectUrls(mu.play_url || mu.playUrl),
      // 统计数据（%LIKE_COUNT% 等文件名组件用）
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

  // 顺路把响身体里的 `item_id_to_episode` 收进映射表（合集 / 短剧）
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

  // ── 命中处理 ──────────────────────────────────────────────
  function handle(url, data) {
    // 再判一次白名单：shouldWatch 在调用侧，这里拿 kind 给条目打来源标签
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
      // **不直接回传**：先进本页缓存，等页面真的把这张卡片渲染出来再认
      put(it);
    }
    scheduleScan(SCAN_MS);
  }

  // 只收白名单里的端点（见 WATCH_RULES）。
  //
  // 顺手把**所有**见过的 `/aweme/v*/web/` 路径计数（白名单外的也记）：
  // 某个页面一条都抓不到时，得先分清是"抖音这个页面走的接口不在白名单里"
  // 还是"接口来了但 DOM 没匹配上"——这两种的修法完全相反。
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
  //
  // 页面**最上面那几张卡的数据可能根本不走 XHR** —— 抖音服务端直接把 JSON
  // 写进 HTML 的内联 `<script>` 里。只 hook XHR/fetch 就永远看不见它，
  // 表现就是用户说的"上面先出来的视频没抓到"（2026-09-19 真机确认）。
  // 所以文档解析完再补扫一遍内联脚本，把里面的 aweme 也灌进缓存。
  //
  // 这不会放宽"只认页面上有的"这道闸：缓存只是**候选池**，认不认仍由 DOM 决定。
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

  // 内联脚本里的 JSON 有这几种写法，逐个试到通为止
  function looseJson(text) {
    var s = text.replace(/^[\s\uFEFF]+/, '');
    var obj = tryParse(s);
    if (obj) { return obj; }
    // window._ROUTER_DATA = {...};
    var eq = s.indexOf('=');
    if (eq > 0 && eq < 200) {
      obj = tryParse(s.slice(eq + 1).replace(/;[\s\S]*$/, '').replace(/^[\s\uFEFF]+/, ''));
      if (obj) { return obj; }
    }
    // <script id="RENDER_DATA">{URL 编码后的 JSON}</script>
    if (s.indexOf('%7B') === 0 || s.indexOf('%22aweme_id%22') > 0) {
      try { obj = tryParse(decodeURIComponent(s)); } catch (e) { obj = null; }
      if (obj) { return obj; }
    }
    // 兜底：截第一个 { 到最后一个 }
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

  // ── 重扫触发 ──────────────────────────────────────────────
  //
  // 响应到的那一刻页面往往还没把新卡片挂进 DOM（React 要下一帧才渲染），
  // 而卡片也可能要等用户滚动到视口才挂载。所以不能只在响应时扫一次 ——
  // 靠一个 1.5 秒的轮询把缓存重跑一遍
  // 的 eF.init），这里再加一个 scroll 让滚动时立刻跟上。
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
    // 只处理 JSON 开头（{ / [），避免把 HTML 也拿去 JSON.parse
    if (s !== 123 && s !== 91) { return null; }
    try { return JSON.parse(txt); } catch (e) { return null; }
  }

  // ── Hook XHR ─────────────────────────────────────────────
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

  // ── Hook fetch ───────────────────────────────────────────
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

  // 给 Dart 侧「诊断」按钮用：把页面上到底有哪些可识别的节点如实倒出来。
  // 认不出条目时（列表比屏幕上的少）这是唯一的取证手段 —— 光看回传条数
  // 分不清是"抖音没发请求"还是"请求来了但 DOM 匹配不上"。
  function domCensus() {
    var c = {
      path: '', nodes: 0, cache: cacheSize, hit: 0,
      from: { href: 0, e2e: 0, attr: 0, url: 0 },
      attrSample: [], noData: [], endpoints: pathTally,
      // 按类型拆开数 —— 「图文没有黄框」这一类问题，三种成因的修法完全相反：
      //   byCache.images = 0        → 图文根本没进缓存（解析或端点白名单问题）
      //   byCache.images > 0 而 byHit.images = 0
      //                               → 缓存有、DOM 没对上（scanDom 认不出 /note/ 卡片）
      //   byHit.images > 0 而 byMark.images = 0
      //                               → 对上了但描框没生效（样式被覆盖 / 标到了零尺寸节点）
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

  // 给 Dart 侧「诊断」按钮用：确认脚本挂上没、捞到几条
  window.__pdDouyinInfo = function () {
    var eps = 0;
    for (var k in episodeMap) { eps++; }
    return {
      hooked: true,
      // captured = 接口里解析出来的作品数；identified = 其中页面真渲染出来、
      // 已经认下来的条数。两者差距大 = 抖音在预取用户没看到的下一页，
      // 正是这一版要把住的那道闸。
      captured: captured,
      identified: identified,
      marked: marked,
      cached: cacheSize,
      rendered: renderedIds,
      pending: queueLen,
      episodes: eps,
      // 各端点类别各贡献了多少条 —— 抖音改版导致某个端点没数据时，
      // 一眼能看出是哪一类掉的（白名单见 WATCH_RULES）
      kinds: kindCount,
      dom: domCensus()
    };
  };
})();
""";
