// 抖音注入脚本的「只认页面真渲染出来的作品」行为检查。
//
// 跑法：`node tool/douyin_dom_gate.mjs`（只用 node 内置模块，无需装依赖）。
// **它不在 `flutter test` 里**：被测对象是 `douyin_interceptor_js.dart` 里的
// JS 字符串，Dart 测试跑不动它；开发机上也没装 node（2026-09-19 确认），
// 所以这份检查目前是手动的。改完注入脚本至少要过一遍语法那道关：
// 脚本会先把 JS 抽出来 `new vm.Script()` 编译一次。
//
// 做法：造一个假 DOM 把注入脚本跑在 vm 沙箱里，用假 XHR 喂接口响应、
// 用假 `<script>` 喂首屏 SSR 数据，然后断言 postMessage 回传的内容。
// 覆盖的是用户能直接看见、而且已经真机报过 bug 的几件事：
//   1. 接口下发 20 条、页面只渲染 3 张卡 → 只回传那 3 条（不预解析）；
//   2. 滚出新卡片补传，旧的不重传；认下来的卡片带 #ffb600 黄框；
//   3. 顺序按页面从上到下，不是按接口到货顺序；
//   4. 精选页那种「卡片不是 <a>、作品 id 挂在元素 id 上」的版面要能认；
//   5. 首屏数据不走 XHR（服务端写进 HTML）时也要能认。

import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dartPath = path.join(repoRoot, 'lib', 'services', 'douyin_interceptor_js.dart');

function extractJs() {
  const src = fs.readFileSync(dartPath, 'utf8');
  const open = src.indexOf('r"""');
  if (open < 0) throw new Error(`${dartPath} 里找不到 r""" 开头的脚本正文`);
  const close = src.indexOf('"""', open + 4);
  if (close < 0) throw new Error(`${dartPath} 的脚本正文没有闭合的三引号`);
  return src.slice(open + 4, close);
}

const interceptorJs = extractJs();

/// 复合选择器 → 假 DOM 上的等价过滤。注入脚本只用这几个。
const SELECTORS = {
  'a[href]': (n) => !!n.href,
  '[data-e2e-aweme-id]': (n) => !!n._e2e,
  '[id]': (n) => !!n.id,
  'a[href], [data-e2e-aweme-id], [id]': (n) => !!(n.href || n._e2e || n.id),
};

function boot() {
  const nodes = []; // 数组顺序 == 文档顺序（注入脚本靠这个排序）
  const scripts = [];
  const posted = [];
  const docListeners = {};
  const winListeners = {};

  function makeNode(o) {
    return {
      tagName: o.tag || 'A',
      className: o.cls || '',
      href: o.href || '',
      id: o.id || '',
      _e2e: o.e2e || '',
      _attrs: {},
      style: {},
      getAttribute(k) {
        if (k === 'data-e2e-aweme-id') return this._e2e || null;
        return this._attrs[k] === undefined ? null : this._attrs[k];
      },
      setAttribute(k, v) {
        this._attrs[k] = String(v);
      },
    };
  }

  const document = {
    hidden: false,
    readyState: 'loading',
    querySelectorAll(sel) {
      const f = SELECTORS[sel];
      return f ? nodes.filter(f) : [];
    },
    getElementsByTagName: () => scripts.slice(),
    addEventListener(t, cb) {
      (docListeners[t] = docListeners[t] || []).push(cb);
    },
  };
  const window = {
    chrome: { webview: { postMessage(m) { posted.push(m); } } },
    addEventListener(t, cb) {
      (winListeners[t] = winListeners[t] || []).push(cb);
    },
  };
  const location = { pathname: '/', href: 'https://www.douyin.com/', search: '' };

  function FakeXhr() {
    this._listeners = {};
    this.responseText = '';
    this.response = null;
    this.responseType = '';
  }
  FakeXhr.prototype.open = function (_m, url) {
    this.__pdUrl = String(url);
  };
  FakeXhr.prototype.addEventListener = function (t, cb) {
    (this._listeners[t] = this._listeners[t] || []).push(cb);
  };
  FakeXhr.prototype.send = function () {
    const self = this;
    setTimeout(() => {
      (self._listeners['load'] || []).forEach((cb) => cb.call(self));
    }, 0);
  };

  const context = vm.createContext({
    window, document, console, location,
    XMLHttpRequest: FakeXhr,
    URL, JSON, Object, Array, String, Number, Math, RegExp, Date, Error,
    isFinite, parseInt, decodeURIComponent, encodeURIComponent,
    setTimeout, clearTimeout, setInterval, clearInterval,
  });
  vm.runInContext(interceptorJs, context, { filename: 'douyin_interceptor.js' });

  return {
    location,
    makeNode,
    /// 往假页面里加一张卡片。返回值就是可能被描框的那个节点。
    add(o) {
      const n = makeNode(o);
      nodes.push(n);
      return n;
    },
    /// 加一段内联 `<script>`（模拟服务端写进 HTML 的首屏数据）
    addScript(textContent) {
      scripts.push({ textContent });
    },
    /// 让文档进入"HTML 已解析完"，注入脚本会在此刻扫内联脚本
    fireReady() {
      document.readyState = 'interactive';
      (docListeners['DOMContentLoaded'] || []).forEach((cb) => cb());
    },
    respond(url, body) {
      const x = new FakeXhr();
      x.responseText = JSON.stringify(body);
      x.open('GET', url);
      x.send();
    },
    reported() {
      return posted.flatMap((m) => m.items).map((i) => i.id);
    },
    cards() {
      return nodes.slice();
    },
    /// 模拟 SPA 换页：整棵卡片子树被卸载
    clearNodes() {
      nodes.length = 0;
    },
    info() {
      return window.__pdDouyinInfo();
    },
  };
}

function aweme(id) {
  return {
    aweme_id: String(id),
    desc: `作品 ${id}`,
    create_time: 1700000000,
    author: { nickname: `作者 ${id}`, unique_id: `u${id}` },
    statistics: { digg_count: 10, comment_count: 1 },
    video: {
      duration: 5000,
      ratio: '1080p',
      play_addr: {
        url_list: [`https://p3.douyin.com/video/${id}.mp4`],
        width: 1080,
        height: 1920,
      },
    },
  };
}

const ids = (prefix, n) => Array.from({ length: n }, (_, i) => `${prefix}${1000 + i}`);
const card = (id) => ({ href: `https://www.douyin.com/video/${id}` });
const feedUrl = 'https://www.douyin.com/aweme/v1/web/module/feed/?device_platform=webapp';
const settled = (ms = 1200) => new Promise((r) => setTimeout(r, ms));

let failures = 0;
function check(name, pass, detail) {
  if (!pass) failures++;
  console.log(`${pass ? '  ok  ' : ' FAIL '} ${name}${detail ? `  —— ${detail}` : ''}`);
}

async function main() {
  console.log(`注入脚本 ${interceptorJs.length} 字符，语法编译通过\n`);

  console.log('① 接口 20 条 / 页面只渲染 3 张卡');
  {
    const s = boot();
    const all = ids('75920000000000', 20);
    all.slice(0, 3).forEach((i) => s.add(card(i)));
    s.respond(feedUrl, { aweme_list: all.map(aweme) });
    await settled();
    const got = s.reported();
    check('只回传页面上那 3 条', got.length === 3 && all.slice(0, 3).every((i) => got.includes(i)), `回传 ${got.length} 条`);
    check('接口侧确实收到 20 条（不是没拦到）', s.info().captured === 20, `captured=${s.info().captured} cached=${s.info().cached}`);
    const bordered = s.cards().filter((a) => a.getAttribute('data-has-marked'));
    check('3 张卡都描了黄框', bordered.length === 3);
    check('黄框颜色是 #ffb600', bordered.every((a) => a.style.border === '2px solid #ffb600'), JSON.stringify(s.cards()[0].style));
  }

  console.log('\n② 滚出 4 张新卡片');
  {
    const s = boot();
    const all = ids('75921000000000', 20);
    all.slice(0, 3).forEach((i) => s.add(card(i)));
    s.respond(feedUrl, { aweme_list: all.map(aweme) });
    await settled();
    const before = s.reported();
    all.slice(3, 7).forEach((i) => s.add(card(i)));
    await settled();
    const after = s.reported();
    check('补传 4 条', after.length === 7 && after.slice(before.length).join() === all.slice(3, 7).join(), `${before.length} → ${after.length}`);
    check('旧条目不重传', after.slice(0, before.length).join() === before.join());
    check('7 张卡全部描框', s.cards().every((a) => a.getAttribute('data-has-marked') === '1'));
  }

  console.log('\n③ 顺序：必须按页面从上到下，不是按接口到货顺序');
  {
    const s = boot();
    const all = ids('75921500000000', 6);
    // 页面上把卡片倒着挂（第 6 张在最上面），接口仍按 1..6 下发
    all.slice().reverse().forEach((i) => s.add(card(i)));
    s.respond(feedUrl, { aweme_list: all.map(aweme) });
    await settled();
    check('回传顺序 == DOM 顺序', s.reported().join() === all.slice().reverse().join(), s.reported().join());
  }

  console.log('\n④ 竖屏信息流：卡片不是 <a>，靠 data-e2e-aweme-id');
  {
    const s = boot();
    const all = ids('75922000000000', 5);
    s.add({ tag: 'DIV', e2e: all[1] });
    s.add({ tag: 'DIV', e2e: all[4] });
    s.respond('https://www.douyin.com/aweme/v1/web/tab/feed/?x=1', { aweme_list: all.map(aweme) });
    await settled();
    check('只认那 2 个节点对应的作品', s.reported().join() === [all[1], all[4]].join(), JSON.stringify(s.reported()));
  }

  console.log('\n⑤ 精选页：46 个 a[href] 里没有作品 id，id 挂在元素 id 上');
  {
    const s = boot();
    const all = ids('75922500000000', 8);
    // 页面导航链接一堆，但都不含作品 id —— 这正是 2026-09-19 普查到的形状
    ['/', '/jingxuan', '/follow', '/friend', '/live', '/user', '/music', '/movie',
     '/discover', '/download', '/ranking', '/hashtag', '/challenge', '/note',
     '/video', '/search', '/creator', '/school', '/jobs', '/about',
     '/a/b', '/c/d', '/e/f', '/g/h', '/i/j', '/k/l', '/m/n', '/o/p',
     '/q/r', '/s/t', '/u/v', '/w/x', '/y/z', '/aa/bb', '/cc/dd', '/ee/ff',
     '/gg/hh', '/ii/jj', '/kk/ll', '/mm/nn', '/oo/pp', '/qq/rr', '/ss/tt',
     '/uu/vv', '/ww/xx', '/yy/zz', '/0/1', '/2/3'].forEach((p) => s.add({ href: `https://www.douyin.com${p}` }));
    all.slice(0, 5).forEach((i) => s.add({ tag: 'DIV', cls: 'card', id: `item_${i}` }));
    s.respond(feedUrl, { aweme_list: all.map(aweme) });
    await settled();
    check('5 张卡靠 id 属性认出来', s.reported().length === 5, `回传 ${s.reported().length} 条`);
    check('48 个无关链接没造成误报', s.reported().length === 5 && s.info().cached === 8);
    const census = s.info().dom;
    check('普查把这种命中记为 attr 来源', census.from.attr === 5, JSON.stringify(census.from));
  }

  console.log('\n⑥ 详情页：作品 id 只在地址上');
  {
    const s = boot();
    const all = ids('75923000000000', 2);
    s.location.pathname = `/video/${all[1]}`;
    s.location.href = `https://www.douyin.com/video/${all[1]}`;
    s.respond('https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=1', { aweme_list: all.map(aweme) });
    await settled();
    check('只认地址里那一条', s.reported().join() === all[1], JSON.stringify(s.reported()));
  }

  console.log('\n⑦ 切走再切回（SPA 会重建整棵 DOM）');
  {
    const s = boot();
    const all = ids('75924000000000', 2);
    s.add(card(all[0]));
    s.respond('https://www.douyin.com/aweme/v1/web/aweme/post/?sec_uid=x', { aweme_list: all.map(aweme) });
    await settled();
    const first = s.reported().slice();
    s.location.pathname = '/user/MS4wLjABAAAA';
    s.clearNodes();
    await settled();
    s.location.pathname = '/';
    const fresh = s.add(card(all[0]));
    await settled();
    check('不重复回传', s.reported().join() === first.join(), JSON.stringify(s.reported()));
    check('新节点重新描上黄框', fresh.style.border === '2px solid #ffb600', JSON.stringify(fresh.style));
  }

  console.log('\n⑧ 白名单外的端点（搜索）');
  {
    const s = boot();
    const all = ids('75925000000000', 1);
    s.add(card(all[0]));
    s.respond('https://www.douyin.com/aweme/v1/web/general/search/single/?kw=x', { aweme_list: all.map(aweme) });
    await settled();
    check('一条都不收', s.reported().length === 0 && s.info().captured === 0);
  }

  console.log('\n⑨ 网格页一次刷出 8 张卡，下滑再加 5 张');
  {
    const s = boot();
    const all = ids('75926000000000', 20);
    all.slice(0, 8).forEach((i) => s.add(card(i)));
    s.respond(feedUrl, { aweme_list: all.map(aweme) });
    await settled();
    const got = s.reported();
    check('8 张卡一次全收', got.length === 8, `回传 ${got.length} 条`);
    check('收的正是屏幕上那 8 个', all.slice(0, 8).every((i) => got.includes(i)));
    check('预取的另外 12 条没混进来', s.info().cached === 20 && got.length === 8);
    all.slice(8, 13).forEach((i) => s.add(card(i)));
    await settled();
    check('下滑后累加到 13 条', s.reported().length === 13, `${got.length} → ${s.reported().length}`);
    check('顺序仍是页面从上到下', s.reported().join() === all.slice(0, 13).join());
  }

  console.log('\n⑩ 首屏数据不走 XHR（服务端写进 HTML 的 SSR）');
  {
    const s = boot();
    const all = ids('75927000000000', 4);
    // 首屏 4 张卡已在页面上，但没有任何接口响应带着它们
    all.forEach((i) => s.add(card(i)));
    s.addScript(
      'window._ROUTER_DATA = ' +
      JSON.stringify({ loaderData: { 'jingxuan-page': { aweme_list: all.map(aweme) } } }) +
      ';',
    );
    s.fireReady();
    await settled();
    check('SSR 里的首屏卡片被认出来', s.reported().length === 4, `回传 ${s.reported().length} 条`);
    check('顺序按页面从上到下', s.reported().join() === all.join());
    check('诊断里能看出来源是 ssr', s.info().kinds.ssr === 4, JSON.stringify(s.info().kinds));
  }

  console.log(`\n${failures === 0 ? '全部通过' : `${failures} 项失败`}`);
  return failures;
}

/// 顶层不 await：这样 `node tool/douyin_dom_gate.mjs` 直接跑完自然退出，
/// 而想拿到结果（比如在 REPL 里）可以 `import(...).then(m => await m.ready)`。
export const ready = main().then((f) => {
  // 用 `node tool/douyin_dom_gate.mjs` 跑时退出码非 0；在其他宿主（如 node
  // REPL 沙箱）里没有 process，跳过即可，不影响上面的输出。
  globalThis.process?.exit(f === 0 ? 0 : 1);
  return f;
});
