/// 英文文案表：**key 是中文原文**，value 是英文。
///
/// 组织方式与覆盖面见 `l10n.dart` 的库注释。加一条就要在这里加一条 ——
/// `test/l10n_test.dart` 会扫源码里所有 `t('…')` 字面量，漏翻和留旧条目都会失败。
const Map<String, String> kStringsEn = {
  '重试全部（{n}）': 'Retry all ({n})',
  '重试中…': 'Retrying…',
  '已重新排队 {ok} 个，{skip} 个文件已在磁盘上无需重下，{fail} 个没成功':
      'Re-queued {ok}, {skip} already on disk, {fail} failed',
  // ── 导航（widgets/nav_items.dart 的 label，渲染处过 t()）────────
  //
  // 导航标签刻意收短：侧边栏只有 240px，'Download Manager' 会被截成
  // `Download Manag…`（2026-09-21 真机截图）。子项本来就挂在模块下面，
  // 'Downloads' 不会歧义；其它页面里出现「下载管理」时仍译作 Download Manager。
  'X 下载': 'X Downloads',
  '抖音解析下载': 'Douyin Downloads',
  '主页': 'Home',
  '下载管理': 'Downloads',
  '自动执行': 'Auto Tasks',
  '设置': 'Settings',
  '解析下载': 'Parse & Download',
  '自动下载': 'Auto Download',
  '关于': 'About',

  // ── 标题栏 ───────────────────────────────────────────────────
  '解析下载器': 'Parse Downloader',
  '最小化': 'Minimize',
  '最大化': 'Maximize',
  '还原': 'Restore',
  '关闭': 'Close',
  '切换到{label}': 'Switch to {label}',
  '切换到{label}（当前）': 'Switch to {label} (current)',
  '{label} 模块': '{label} module',
  '点击收起': 'click to collapse',
  '点击展开': 'click to expand',
  '{label}节点，{hint}': '{label} section, {hint}',

  // ── 设置页 ───────────────────────────────────────────────────
  // 三条导航项与标题栏共用同一批 key（导航 label 现在也自带归属）。
  'X 下载设置': 'X Download Settings',
  '抖音设置': 'Douyin Settings',
  '全局设置': 'General Settings',
  '抖音解析下载设置': 'Douyin Download Settings',
  '外观': 'Appearance',
  '窗口材质、自定义色调、导航形态、主题模式、背景图片、界面语言':
      'Window material, custom tint, navigation style, theme mode, background image, language',
  '展开设置': 'Show settings',
  '窗口材质': 'Window material',
  '云母材质需要 Windows 11，亚克力需要 Windows 10 1809 以上；系统不支持时会退回纯色背景。':
      'Mica requires Windows 11 and acrylic requires Windows 10 1809 or newer. '
      'Unsupported systems fall back to a solid background.',
  '界面风格': 'Interface style',
  // 「总览」是首个导航项（置顶，不属于三个模块），也是标题栏文案。
  '总览': 'Overview',
  // 总览页（dashboard_page.dart）的文案。
  '进行中': 'In progress',
  '下载台账': 'Download ledger',
  '磁盘占用': 'Disk usage',
  '下载引擎就绪': 'Download engine ready',
  '下载引擎未就绪': 'Download engine not ready',
  '快捷开始': 'Quick start',
  '点一下直达': 'One tap to jump there',
  '最近活动': 'Recent activity',
  '来自下载任务': 'From download tasks',
  '还没有下载任务': 'No download tasks yet',
  '等待中': 'Waiting',
  '排队中': 'Queued',
  '已暂停': 'Paused',
  '模块状态': 'Module status',
  '进行中 / 已下载': 'In progress / downloaded',
  '下载引擎': 'Download engine',
  '正在下载': 'Downloading',
  '任务总数': 'Total tasks',
  'aria2 正在运行': 'aria2 is running',
  '环境': 'Environment',
  '未初始化': 'Not initialised',
  '日志': 'Logs',
  '已开启': 'On',
  '已关闭': 'Off',
  // 统计卡的数字量词。中文是「3 个 / 3 条」，英文不加量词 ——
  // 留空串而不是删条目：`l10n_test` 要求每个 t() 的中文都有对照，
  // 且空串在拼装处自然消失（数字与单位之间不加空格由调用方处理）。
  '个': '',
  '条': '',
  '卡片用哪种材质表达：液体玻璃最透亮、磨砂清晰最清楚、陶土柔和是实心面。切换后立即生效，并在下次启动时保留。':
      'How cards express their material: liquid glass is the most translucent, '
      'frosted stays the clearest, and clay is a solid surface. Takes effect '
      'immediately and is kept across restarts.',
  '液体玻璃': 'Liquid glass',
  '多层渐变加内缘亮环，模糊最轻、透光最强':
      'Layered gradients and a bright inner rim — lightest blur, most light through',
  '磨砂清晰': 'Frosted',
  '单层磨砂，模糊与不透明度取中，文字最清楚':
      'A single frosted layer, medium blur and opacity — the clearest text',
  '陶土柔和': 'Clay',
  '实心面配更重的软阴影，完全不透明，性能最好':
      'A solid surface with a heavier soft shadow, fully opaque and the cheapest to draw',
  '自定义色调': 'Custom tint',
  '开启后用选定颜色给窗口底色染色，让材质效果更明显。需要先选择「云母」或「亚克力」材质。':
      'Tints the window background with the chosen color so the material effect '
      'shows through. Requires the Mica or acrylic material.',
  '导航形态': 'Navigation style',
  '选择主界面用哪种导航：底部悬浮 Dock，或左侧常规侧边栏。两者展示完全相同的页面与顺序，切换后立即生效，并在下次启动时保留。':
      'Pick the main navigation: a floating Dock at the bottom, or a regular '
      'sidebar on the left. Both show the same pages in the same order. '
      'Takes effect immediately and is kept across restarts.',
  '主题模式': 'Theme mode',
  '选择「跟随系统」后，应用会随 Windows 的浅色/深色设置自动切换。':
      'With Follow system, the app switches between light and dark along with Windows.',
  '界面语言': 'Language',
  '选择应用界面的语言。选「跟随系统」时，系统语言为中文就用中文，否则用英文。切换后立即生效，并在下次启动时保留。':
      'Choose the interface language. Follow system picks Chinese when the '
      'system language is Chinese, and English otherwise. Takes effect '
      'immediately and is kept across restarts.',
  '跟随系统': 'Follow system',
  '简体中文': 'Simplified Chinese',
  '浅色': 'Light',
  '深色': 'Dark',
  '背景图片': 'Background image',
  '导入一张本地图片作为主界面背景，可调节不透明度以配合窗口材质。':
      'Use a local image as the app background, with an opacity slider to match the window material.',
  '账号': 'Account',
  '登录状态、cookie 输入与验证': 'Sign-in state, cookie input and verification',
  '下载': 'Downloads',
  '保存路径、文件夹 / 文件名模板、同名文件处理':
      'Save path, folder / file name templates, duplicate handling',
  '抖音': 'Douyin',
  '下载源、质量优先策略、图片格式、批量与筛选选项':
      'Download source, quality priority, image format, batch and filter options',
  '代理': 'Proxy',
  '启用代理、使用系统代理、自定义代理地址、连通性测试':
      'Enable proxy, use system proxy, custom proxy address, connectivity test',
  // 「接口缓存」原本是全局设置里的「高级」分区，现在整块归到 X 下载设置页。
  '接口缓存': 'API cache',
  'X 接口标识缓存（搜索用户或加载媒体失败时使用）':
      'X GraphQL operation-id cache (used when user search or media loading fails)',
  // 全局设置里的「分模块设置」入口（三个模块各一行）。
  '分模块设置': 'Per-module settings',
  'X 下载、抖音解析下载、B 站解析下载各自的设置页入口':
      'Entry points to the X, Douyin and Bilibili settings pages',
  '刷新 X 接口缓存': 'Refresh X API cache',
  '搜索用户或加载媒体失败时（如提示「找不到该用户」或长时间无响应），通常是 X 更换了内部接口标识。点此清除缓存后重新搜索即可。':
      'When user search or media loading fails ("user not found", or no response '
      'for a long time), X has usually rotated its internal operation ids. '
      'Clear the cache here and search again.',
  '清除缓存并重试': 'Clear cache and retry',
  '已清除 X 接口缓存，请重新搜索': 'X API cache cleared — search again',
  '应用': 'Application',
  '日志记录、日志目录与文件': 'Logging, log folder and files',
  '页面「{route}」迁移中': 'Page "{route}" is still being migrated',

  // ── 关于页 ───────────────────────────────────────────────────
  '批量下载 X、抖音与 B 站上的图片与视频':
      'Bulk-download images and videos from X, Douyin and Bilibili',
  '版本号': 'Version',
  '作者': 'Author',
  '许可证': 'License',
  '条款全文': 'Full terms',
  '系统要求': 'Requirements',
  'Windows 10 64 位及以上 · 需 WebView2 Runtime':
      'Windows 10 64-bit or newer · WebView2 Runtime required',
  '本机环境与数据': 'This machine and your data',
  '反馈问题时把这几项一并附上即可。本程序不含遥测、也不自动更新。':
      'Attach these when reporting a problem. The app has no telemetry and never '
      'updates itself.',
  '本机系统': 'System',
  '未检测到（抖音页会加载失败）': 'Not detected (the Douyin page will fail to load)',
  '读取中…': 'Reading…',
  '数据目录': 'Data folder',
  '日志目录': 'Log folder',
  '打开': 'Open',
  '使用的开源组件': 'Open-source components',
  'GPL-2.0-or-later（捆绑 aria2c.exe）': 'GPL-2.0-or-later (bundles aria2c.exe)',
  '微软专有运行时，需系统已安装':
      'Microsoft proprietary runtime, must already be installed',

  // ── X 下载：主页 / 账号 / 代理 ────────────────────────────────
  '下载某个 X 用户的全部媒体': 'Download all media from an X user',
  '输入用户 ID，加载后开始批量下载图片与视频':
      'Enter a user ID, load it, then batch-download the images and videos',
  '历史': 'History',
  '加载': 'Load',
  '清空': 'Clear',
  '该用户暂无媒体': 'This user has no media yet',
  '该用户': 'this user',
  '共 {n} 个媒体': '{n} media items',
  '下载 @{user} 的媒体': 'Download media from @{user}',
  '正在读取该用户的媒体并加入下载队列':
      'Reading this user’s media and queueing downloads',
  '在浏览器登录': 'Sign in via browser',
  '智能导入完整 cookie': 'Import a full cookie',
  '十六进制字符串（约 40 位）': 'Hex string (about 40 characters)',
  '32 位十六进制（CSRF token）': '32-hex-digit (CSRF token)',
  '复制': 'Copy',
  '退出': 'Sign out',
  '获取方式：点「在浏览器登录」登录 x.com → 按 F12 → Application → '
          'Cookies → x.com → 找到 auth_token 与 ct0 两行，双击 Value 列复制值，'
          '分别填到上面两个框。\n省事做法：把整段 cookie（或直接从 DevTools '
          '复制的多行内容）粘进任一框，会自动拆分出这两个值。':
      'How to get them: click Sign in via browser, sign in to x.com, press F12 '
      '→ Application → Cookies → x.com, find the auth_token and ct0 rows, '
      'double-click the Value column to copy each, then paste them into the '
      'two boxes above.\nQuicker: paste the whole cookie string (or the '
      'multi-line copy from DevTools) into either box and both values get '
      'split out automatically.',
  '启用代理': 'Enable proxy',
  '关闭后所有 X API 请求直接连接':
      'When off, all X API requests connect directly',
  '使用系统代理': 'Use system proxy',
  '自动读取 Windows「Internet 选项」里的代理设置（推荐）':
      'Read the proxy from Windows Internet Options (recommended)',
  '自定义代理地址': 'Custom proxy address',
  '还没填代理地址 —— 「测试连接」与下载都会失败':
      'No proxy address yet — both the connectivity test and downloads will fail',
  '已保存': 'Saved',
  '已保存，但{why}': 'Saved, but {why}',
  '下载引擎没能启动，下载会失败。请重启应用；若反复出现，可在「全局设置 → 应用」打开日志后再试一次。':
      'The download engine failed to start, so downloads will fail. Restart the app; if it keeps happening, turn on logging under General Settings → App and try again.',
  '{n} 个任务暂停失败': 'Failed to pause {n} task(s)',
  '内嵌浏览器还没就绪，请稍后再试':
      'The embedded browser is not ready yet, please try again shortly',
  '打开这个地址失败，详见日志': 'Failed to open this address, see the log',
  '这个导航动作失败了，详见日志': 'This navigation action failed, see the log',
  '保存': 'Save',

  // ── X 下载：自动执行 ──────────────────────────────────────────
  '批量任务已启动，可切到下载管理查看进度':
      'Batch started — switch to Download Manager for progress',
  '批量任务正在后台执行，切换到其他页面也不会中断，回来即可继续查看进度。':
      'The batch keeps running in the background when you leave this page; '
      'come back to see the progress.',
  '尚未登录 X 账号，请先在【设置】中登录后再执行批量任务。':
      'You are not signed in to X. Sign in under Settings first, then run the batch.',
  '说明：任务创建后会进入后台队列串行执行，实际下载进度请到【下载管理】查看。':
      'Note: created tasks run one by one in a background queue — see Download '
      'Manager for the actual progress.',
  '选择 txt 文件': 'Choose a txt file',
  '也可以直接粘贴，每行一个：\n'
          'example_user\n@sample_media_01\nhttps://x.com/demo_handle':
      'Or paste them directly, one per line:\n'
      'example_user\n@sample_media_01\nhttps://x.com/demo_handle',
  '已解析 ': 'Parsed ',
  ' 个有效用户 ID': ' valid user IDs',
  '，另有 ': ', and ',
  ' 行无法识别已跳过': ' unrecognised lines skipped',
  '帖子能下载到更早的推文，但爬取速度较慢；媒体可能下载不到更早的推文，'
          '但爬取速度更快。':
      'Posts reach older tweets but crawl more slowly; Media reaches fewer '
      'older tweets but crawls faster.',
  '帖子': 'Posts',
  '媒体': 'Media',
  '每个账号间隔（秒）': 'Delay between accounts (s)',
  '单个加载超时（秒）': 'Per-item load timeout (s)',
  '失败后继续下一个': 'Continue after a failure',
  '开始执行': 'Start run',
  '停止': 'Stop',
  '清空结果': 'Clear results',
  '每页': 'Per page',
  '用户 ID': 'User ID',
  '状态': 'Status',
  '说明': 'Note',
  '历史名单': 'Saved lists',
  '保存当前': 'Save current',
  '还没有保存的名单。粘贴或导入名单后，点「保存当前」即可加入历史。':
      'No saved lists yet. Paste or import a list, then click Save current.',
  '保存为预设': 'Save as preset',
  '取消': 'Cancel',
  '保存失败：名单为空': 'Cannot save: the list is empty',
  '重命名': 'Rename',
  '确定': 'OK',
  '该预设只删除历史记录，不影响当前名单。':
      'This only deletes the saved record; the current list is untouched.',
  '删除': 'Delete',
  '操作': 'Actions',
  '共 {n} 个 · 成功 {ok} · 失败 {fail} · 完成 {percent}%':
      '{n} total · {ok} ok · {fail} failed · {percent}% done',
  '第 {from}-{to} 条 / 共 {total}': '{from}-{to} of {total}',
  '删除「{name}」？': 'Delete "{name}"?',
  '{n} 个 · {date}': '{n} items · {date}',

  // ── 抖音：解析下载 / 自动下载 / 设置 ──────────────────────────
  '下载引擎还没起来（aria2 未就绪），请稍后重试或查看日志':
      'The download engine is not ready (aria2) — try again shortly or check the log',
  '已停止自动加载': 'Auto-load stopped',
  '开始自动加载，到底或到上限会自动停':
      'Start auto-load — stops at the bottom or at the limit',
  '粘贴抖音链接 / 作品 ID，回车打开':
      'Paste a Douyin link or post id, press Enter to open',
  '检查拦截脚本状态': 'Check interceptor status',
  '内嵌浏览器不可用': 'Embedded browser unavailable',
  '重试': 'Retry',
  '正在启动内嵌浏览器…': 'Starting the embedded browser…',
  '抓取结果': 'Captured',
  '展开详情列表（覆盖在页面上）':
      'Expand the detail list (overlays the page)',
  '全选': 'Select all',
  '收起': 'Collapse',
  '筛选抓取结果': 'Filter captured items',
  '重置': 'Reset',
  // 「应用」在设置里是分区名（Application），在筛选面板里是按钮 —— 同一中文两义
  'filter:应用': 'Apply',
  '已下载': 'Downloaded',
  '已抓 {n}': '{n} captured',
  '已选 {n}': '{n} selected',
  '{n} 个作品': '{n} posts',
  '共 {n} 个作品': '{n} posts in total',
  '当前页面：{page}': 'Current page: {page}',
  '首页': 'Home',
  '作者主页 / 作品链接 / 短链 / 纯作品 ID，一行一个\n'
          '分享口令整段粘进来也能认出链接':
      'Author profile / post link / short link / bare post id, one per line\n'
      'Pasting a whole share text still gets the link out of it',
  '从 txt 导入': 'Import from txt',
  '每个目标最多滚动轮数': 'Max scroll rounds per target',
  '一轮约 0.7 秒。作者主页作品多就调大些；太小会漏掉后面的作品。':
      'Each round takes about 0.7 s. Raise it for accounts with many posts; '
      'too low a value misses the later ones.',
  '{n} 轮': '{n} rounds',
  '在上面填一批链接，再点右上角「开始」。':
      'Fill in a batch of links above, then press Start in the top-right corner.',
  '开始': 'Start',
  '正在准备内嵌浏览器…': 'Preparing the embedded browser…',
  '跑批时这里会自动打开每个目标并往下滚，不用手动操作。'
          '如果提示登录，可以直接在这里登录 —— 登录态与「解析下载」共用。':
      'During a run this opens each target and scrolls on its own, no manual '
      'steps. If it asks you to sign in, do it right here — the session is '
      'shared with Parse & Download.',
  '运行中 · 第 {i}/{total} 个 · {label}': 'Running · target {i}/{total} · {label}',
  '未开始 · {n} 个目标待处理': 'Not started · {n} targets pending',
  '已结束 · 完成 {done}/{total} · 下载 {n} 个媒体':
      'Finished · {done}/{total} done · {n} media downloaded',
  '超出上限：多出的 {n} 个目标被忽略（一次最多 {max} 个）':
      'Over the limit: {n} extra targets ignored (at most {max} per run)',
  '认不出的 {n} 行已忽略：{head}{more}':
      '{n} unrecognised lines ignored: {head}{more}',
  '已抓到 {n} 个作品': 'Collected {n} posts',
  '提交 {q} / {total}': 'Submitting {q} / {total}',
  '下载 {n} 个': 'Downloaded {n}',
  '跳过 {n} 个已下载': 'Skipped {n} already downloaded',
  '轮数用尽，可能没翻完': 'rounds used up, may not have reached the bottom',
  '都是已下载的（跳过 {n} 个）': 'All already downloaded (skipped {n})',
  '这个页面上没抓到作品': 'No posts captured on this page',
  '，': ', ',
  '例如：抖音收藏': 'e.g. Douyin favourites',
  '选择': 'Choose',
  '留空则使用 %USERPROFILE%\\Downloads\\解析下载器':
      'Leave empty to use %USERPROFILE%\\Downloads\\Parse Downloader',
  '自定义（已手动修改）': 'Custom (edited)',
  '文件夹模板': 'Folder template',
  '文件模板': 'File template',
  '文件名模板': 'File name template',
  '改动会自动保存': 'Changes are saved automatically',
  '已清除抖音下载记录': 'Douyin download history cleared',
  '清除失败：记录文件写入出错，记录还在':
      'Clear failed: the record file could not be written, records are still there',
  '文件已经在磁盘上，没有重复下载':
      'The file is already on disk, nothing was downloaded again',
  '重试失败：下载引擎拒绝了这条任务':
      'Retry failed: the download engine rejected this task',
  '重试已取消：旧任务没能从下载引擎里移除，它还留在列表里':
      'Retry cancelled: the old task could not be removed from the download '
      'engine, it is still in the list',
  '下载引擎还没起来（aria2 未就绪），请稍后重试':
      'The download engine is not ready yet (aria2), please retry shortly',
  '清除下载记录': 'Clear download history',
  '已插入 {token} 到「{target}」': 'Inserted {token} into "{target}"',

  // ── 下载管理 / 模板 / 应用分区 ────────────────────────────────
  'aria2 未启动，请稍候或重启应用':
      'aria2 is not running yet — wait a moment or restart the app',
  '全部暂停': 'Pause all',
  '全部继续': 'Resume all',
  '清空已完成': 'Clear completed',
  '暂停': 'Pause',
  '继续': 'Resume',
  '打开文件夹': 'Open folder',
  '移除': 'Remove',
  '引擎里已经没有它了，已从列表移除':
      'It was no longer in the download engine — removed from the list',
  '共 {n} 个任务创建中': '{n} tasks being created',
  '已发送：{n}': 'Sent: {n}',
  '已跳过：{n}': 'Skipped: {n}',
  '失败：{n}': 'Failed: {n}',
  'aria2 拒绝了这些任务，详情见「失败」Tab':
      'aria2 rejected these tasks — see the "Error" tab',
  '以下几种情况会跳过：\n'
          '1. 文件名已存在且开启了「跳过相同文件」开关；\n'
          '2. 推文时间超出设定的日期范围。':
      'These cases are skipped:\n'
      '1. the file name already exists and "Skip same file name" is on;\n'
      '2. the tweet date falls outside the configured range.',
  '还没有下载记录': 'No download records yet',
  '勾选作品加入下载队列后就会记在这里。\n'
          '记录按「作品」计，下次批量下载会跳过它们。':
      'Posts you queue for download get recorded here.\n'
      'Records count whole posts, so the next batch run skips them.',
  '从历史中移除（下次会重新下载）':
      'Remove from history (will download again next time)',
  '清空下载历史？': 'Clear the download history?',
  '清空之后，下次批量下载就不会再跳过这些作品了。':
      'After clearing, the next batch run will no longer skip these posts.',

  // ── 下载管理：B 站的「已下载（B 站）」历史分区 ─────────────────
  //
  // 「清空下载历史？」「从历史中移除…」「还没有下载记录」「清除失败…」这几句
  // 两边共用（说法本身不带平台名），所以不重复开 key；带平台名的必须各一条。
  '共 {n} 个分P': '{n} parts in total',
  '在 B 站解析下载页勾选分P并下完之后就会记在这里。\n'
          '记录按「分P」计，把文件移走或删掉也仍然算下过。':
      'Parts you finished downloading get recorded here.\n'
      'Records count parts — moving or deleting the files still counts as downloaded.',
  '清空之后，下次批量下载就不会再跳过这些分P了。':
      'After clearing, the next batch run will no longer skip these parts.',
  '已清除 B 站下载记录': 'Bilibili download history cleared',
  'UP 主未知': 'Uploader unknown',
  '时间未知': 'Time unknown',
  '{bv} · 分P {cid}': '{bv} · Part {cid}',

  // ── B 站解析下载页（lib/pages/bili_page.dart）与它的导航入口 ───────
  //
  // 导航标签「解析下载」「下载管理」与抖音共用同一条 key（两个模块的那一行
  // 本来就同名），所以这里只补带归属的那两条 + 这一页自己独有的文案。
  'B 站解析下载': 'Bilibili Downloads',
  // 侧边栏中文档只有 200px，组名用短一档的「B 站下载」（七字标签会被截）。
  'B 站下载': 'Bilibili Downloads',
  'B 站设置': 'Bilibili Settings',
  '后退': 'Back',
  '前进': 'Forward',
  '刷新': 'Refresh',
  'B 站首页': 'Bilibili home',
  '粘贴 B 站链接，回车打开': 'Paste a Bilibili link, press Enter to open',
  '未检测到 Edge WebView2 运行时。\n'
          'Win11 自带；Win10 请安装「Microsoft Edge WebView2 Runtime」后重试。':
      'Edge WebView2 runtime not found.\n'
      'Windows 11 ships it; on Windows 10 install "Microsoft Edge WebView2 Runtime" and retry.',
  '登录状态还没检测': 'Sign-in state not checked yet',
  '正在检测登录状态…': 'Checking the sign-in state…',
  '刷新登录状态': 'Refresh sign-in state',
  '已登录：{name}': 'Signed in: {name}',
  '已登录（没取到昵称）': 'Signed in (no profile name returned)',
  '未登录（只能取到 480P）': 'Not signed in (only 480P available)',
  // 「检测不到」与「未登录」是两件事：前者多半是被风控，叫用户去扫码是误导。
  '检测不到登录状态（被风控或页面没就绪）':
      'Cannot tell the sign-in state (rate-limited, or the page is not ready)',
  '抓当前页': 'Grab this page',
  '抓正在播': 'Grab now playing',
  '内嵌页还停在首页，先在里面打开一条稿件再抓':
      'The built-in browser is still on the home page - open a video in it first',
  '读不到正在播放的稿件号 —— 先在页面里打开一条视频再抓':
      'Cannot read the playing video id - open a video in the page first',
  '读页面失败：{why}': 'Failed to read the page: {why}',
  '解析这条链接': 'Parse this link',
  '粘这条稿件的链接 / BV 号 / b23.tv 短链':
      'Paste the video link / BV id / b23.tv short link',
  '把 B 站稿件链接或 BV 号粘进来再解析':
      'Paste a Bilibili link or BV id first, then parse it',
  '这不是一个能认出来的 B 站链接：{link}':
      'Not a recognisable Bilibili link: {link}',
  '短链没能展开（没有重定向、页面里也找不到 BV 号）':
      'The short link did not expand (no redirect, and no BV id in the page)',
  '这条链接里没有 BV 号也没有 AV 号':
      'This link carries neither a BV nor an AV id',
  '这个稿件没有可下载的分 P（已下架或仅自己可见）':
      'This video exposes no downloadable parts (removed, or visible only to the owner)',
  '清除结果': 'Clear results',
  '正在忙…（取列表 / 取流 / 入队）': 'Working… (listing / fetching streams / queueing)',
  '{n} 个稿件': '{n} videos',
  '已选 {n} / {total} 个分P': '{n} of {total} parts selected',
  '还没有解析结果': 'Nothing parsed yet',
  '在左边打开一条稿件，点「抓当前页」或「抓正在播」；也可以把链接粘到上面再解析。':
      'Open a video in the built-in browser, then use "Grab this page" or '
          '"Grab now playing"; or paste a video link above and parse it.',
  '全部选中': 'Select all',
  '全部取消': 'Select none',
  '上限 {q}': 'Cap: {q}',
  '下载选中的 {n} 个分P': 'Download the {n} selected parts',
  '没有勾选任何分 P': 'No parts are selected',
  '已提交 {n} 条': '{n} queued',
  '跳过 {n} 条（台账里已处理过）': '{n} skipped (already handled in the ledger)',
  '成品已在磁盘 {n} 条': '{n} finished files already on disk',
  '失败 {n} 条': '{n} failed',
  // 抖音页里这句是**没套 t()** 的裸字面量（那边已封存的漏翻），这里补上才有英文。
  '去下载管理': 'Open downloads',

  // 队列空态的引导语：三个模块各一句（入口页名不同），漏一条就是英文界面夹中文。
  '「{name}」里还没有任务': 'Nothing in "{name}" yet',
  '在主页或自动执行页选择媒体后，\n任务会出现在这里':
      'Pick media on the Home page or the Auto Tasks page,\n'
      'and the tasks show up here',
  '在解析下载页或自动下载页勾选作品后，\n任务会出现在这里':
      'Pick posts on the Parse & Download page or the Auto Download page,\n'
      'and the tasks show up here',
  '在 B 站解析下载页勾选分P后，\n任务会出现在这里':
      'Pick parts on the Bilibili Parse & Download page,\n'
      'and the tasks show up here',
  '已保存模板': 'Saved templates',
  '保存模板': 'Save template',
  '模板改动会自动保存': 'Template changes are saved automatically',
  '跳过同名文件': 'Skip same file name',
  '按模板算出的完整路径已存在则跳过，不重新下载':
      'Skip when the full path computed from the template already exists',
  '填入默认': 'Fill defaults',
  '输出示例：': 'Example output:',
  '可用变量': 'Available variables',
  '共 {n} 个，点击插入到本模板':
      '{n} available — click to insert into this template',
  '参数格式：%VARIABLE,a=1,b=2%。': 'Parameter syntax: %VARIABLE,a=1,b=2%.',
  '参数格式：%VARIABLE,a=1,b=2%，如 %{ex}%（{desc}）。':
      'Parameter syntax: %VARIABLE,a=1,b=2%, e.g. %{ex}% ({desc}).',
  '{name}：{desc}（默认：{def}）': '{name}: {desc} (default: {def})',
  '记录日志文件': 'Write log files',
  '开启后把 aria2 输出、X API 请求与错误写入本地日志（不影响应用速度）':
      'When on, aria2 output plus X API requests and errors go to a local log '
      '(does not slow the app down)',
  '日志目录：{path}': 'Log folder: {path}',
  '今天还没有日志文件 —— 请先打开上面的开关，再操作一次':
      'No log file today — turn the switch on above, then do something once',
  '查看日志': 'View log',
  '组内有已改动的设置': 'Some settings in this group have changed',
  '不透明度': 'Opacity',
  '未设置背景图，可导入一张图片作为主界面背景':
      'No background image yet — import one for the main window',
  '导入背景图片': 'Import background image',
  '移除背景图': 'Remove background image',
  '更换图片': 'Change image',
  '自定义调色盘': 'Custom colour',
  '点左侧调色盘按钮展开取色，或直接输入色值':
      'Click the palette button on the left to pick a colour, or type a value',

  // ── 即时提示（toast）与按钮的两种态 ───────────────────────────
  '读取文件失败：{e}': 'Could not read the file: {e}',
  '选择文件失败：{e}': 'Could not pick a file: {e}',
  '打开失败：{e}': 'Could not open it: {e}',
  '已读取 {n} 行有效名单': 'Loaded {n} valid lines',
  '已保存到历史：{name}': 'Saved to history: {name}',
  '保存失败：名单为空，或预设文件写入出错':
      'Save failed: the list is empty, or the preset file could not be written',
  '已读取 {file}：识别出 {n} 个目标': 'Read {file}: {n} targets recognised',
  '先填至少一个目标': 'Fill in at least one target first',
  '内嵌浏览器还没就绪，稍等一下再开始':
      'The embedded browser is not ready yet — give it a moment',
  '下载引擎还没起来（aria2 未就绪），稍后重试':
      'The download engine is not ready (aria2) — try again shortly',
  '已请求停止，当前目标跑完就结束':
      'Stop requested — it ends after the current target',
  '拦截脚本状态：{v}': 'Interceptor status: {v}',
  '无返回': 'no reply',
  '请输入用户 ID': 'Enter a user ID',
  '请输入用户 ID，如：example_user': 'Enter a user ID, e.g. example_user',
  '未登录，点右侧按钮会提示登录':
      'Not signed in — the button on the right will tell you',
  '请先在「设置」中登录 X 账号': 'Sign in to X under Settings first',
  '已加载 @{user}': 'Loaded @{user}',
  '未获取到用户信息，请检查用户 ID 是否正确':
      'No user info returned — check the user ID',
  '已创建下载任务「{name}」，正在后台读取媒体…':
      'Download task created for "{name}" — reading media in the background…',
  '剪贴板为空': 'The clipboard is empty',
  '剪贴板里没有同时找到 auth_token 与 ct0':
      'The clipboard does not contain both auth_token and ct0',
  '剪贴板访问失败': 'Could not read the clipboard',
  '已自动从粘贴内容中提取 auth_token 与 ct0':
      'auth_token and ct0 extracted from the pasted text',
  '已退出登录': 'Signed out',
  '已复制完整 cookie': 'Full cookie copied',
  '下载所选': 'Download selected',
  '开始下载': 'Start download',
  '清空选择': 'Clear selection',
  '验证中…': 'Verifying…',
  '保存并验证': 'Save and verify',
  '测试中…': 'Testing…',
  '测试连接': 'Test connection',

  // ── 数据位标签：枚举 / 常量表（渲染处 t(label)，扫描器抓不到）────
  // 不含汉字的（Mica、H.264、webp）不列 —— 没有该翻的东西。
  '亚克力': 'Acrylic',
  '细亚克力': 'Thin acrylic',
  '纯色': 'Solid colour',
  '柔和云母': 'Soft mica',
  '层次云母': 'Layered mica',
  '磨砂玻璃': 'Frosted glass',
  '更透亮的磨砂': 'Clearer frost',
  '不使用特殊材质，性能最好': 'No special material — the fastest option',
  '悬浮 Dock': 'Floating Dock',
  '常规侧边栏': 'Sidebar',
  '底部居中悬浮，图标式，横向占用小':
      'Floats at the bottom centre, icons only, takes up little width',
  '左侧竖向排列，带文字标签，当前页一目了然':
      'Runs down the left with text labels, so the current page is obvious',
  '视频（默认）': 'Video (default)',
  '下载地址 (H.264)': 'Download URL (H.264)',
  '下载地址 (H.265)': 'Download URL (H.265)',
  '下载地址 (兼容性+质量优先) (H.265/H.264)':
      'Download URL (compatibility + quality) (H.265/H.264)',
  '下载地址 (最高质量优先) (ByteVC1/H.265/H.264)':
      'Download URL (best quality) (ByteVC1/H.265/H.264)',
  '下载地址（仅音频）': 'Download URL (audio only)',
  '自动（推荐）': 'Automatic (recommended)',
  '分辨率优先': 'Resolution first',
  '比特率优先': 'Bitrate first',
  '帧率优先': 'Frame rate first',
  '默认（webp）': 'Default (webp)',
  '其它格式优先（jpg）': 'Prefer other formats (jpg)',
  '任一': 'Any match',
  '全部': 'All match',
  '不限': 'No limit',
  '最近7天': 'Last 7 days',
  '最近30天': 'Last 30 days',
  '最近90天': 'Last 90 days',
  '最近半年': 'Last 6 months',
  '最近一年': 'Last year',
  '等待': 'Waiting',
  '打开页面': 'Opening',
  '收集作品': 'Collecting',
  '提交下载': 'Submitting',
  '完成': 'Done',
  '没收集到': 'Nothing captured',
  '失败': 'Failed',
  '按作者分文件夹（推荐）': 'One folder per author (recommended)',
  '按「作者 / 日期」两级文件夹': 'Two-level folder: author / date',
  '全部平铺（不建子文件夹）': 'Everything flat (no subfolders)',
  '按作品 ID 分文件夹': 'One folder per post ID',

  // ── 模板变量说明（X 侧用「推文」，抖音侧用「作品」，不串台）─────
  '推文 ID': 'Tweet ID',
  '推文发布日期': 'Tweet date',
  '推文内容': 'Tweet text',
  '推文标签': 'Tweet tags',
  '用户昵称': 'Display name',
  '用户名': 'Username',
  '资源 ID': 'Media ID',
  '资源宽度': 'Media width',
  '资源高度': 'Media height',
  '资源索引': 'Media index',
  '媒体类型': 'Media type',
  '扩展名': 'Extension',
  '作者（@昵称）': 'Author (@nickname)',
  '作者 ID': 'Author ID',
  '抖音号': 'Douyin ID',
  '创建时间（YYYYMMDDHHmmss）': 'Created at (YYYYMMDDHHmmss)',
  '作品描述': 'Post description',
  '图集序号（0 起，作品主视频不带）':
      'Image index (starts at 0; the post’s main video has none)',
  '作品 ID': 'Post ID',
  '自定义文本': 'Custom text',
  '分辨率（WxH）': 'Resolution (WxH)',
  '比特率': 'Bitrate',
  '帧率': 'Frame rate',
  '时长': 'Duration',
  '文件大小': 'File size',
  '点赞数': 'Likes',
  '评论数': 'Comments',
  '收藏数': 'Favourites',
  '分享数': 'Shares',
  '仅日期（0 或 1）': 'Date only (0 or 1)',
  '截断长度': 'Truncation length',
  '最大长度（1~120）': 'Max length (1–120)',

  // ── 下载管理的 Tab 名（同时是「当前 Tab」的存储键，只在显示处翻）──
  '下载中': 'Downloading',
  '错误': 'Error',
  '已完成': 'Completed',
  '已下载（抖音）': 'Downloaded (Douyin)',
  '已下载（B 站）': 'Downloaded (Bilibili)',
  '作品标题': 'Title',
  '分P标题': 'Part title',
  '分P序号': 'Part number',
  '分P总数': 'Total parts',
  'BV号': 'BV id',
  'av号': 'AV id',
  '内容ID': 'Content id',
  'UP主昵称': 'Uploader name',
  'UP主ID': 'Uploader id',
  '画质': 'Quality',
  '编码格式': 'Codec',
  '补零位数（0=按分P总数自动）': 'Zero-pad width (0 = auto by part count)',
  '最高可用': 'Highest available',
  '1080P 60帧': '1080P 60fps',
  '自动（兼容性优先）': 'Auto (compatibility first)',
  '按作品分文件夹（推荐）': 'Folder per video (recommended)',
  '按「UP 主 / 作品」两级文件夹': 'Two-level folder (uploader / video)',
  '按 BV 号分文件夹': 'Folder by BV id',

  // ── B 站设置分区（lib/widgets/bili_section.dart）─────────────────
  //
  // 「保存与命名」那一段里能复用上面已有 key 的都复用了（启用保存文件夹 /
  // 启用模版 / 文件夹模板 / 改动会自动保存……），这里只列 B 站自己那些。
  'B 站': 'Bilibili',
  'B 站解析下载设置': 'Bilibili Settings',
  '画质上限、编码偏好、下载完合并、命名模板':
      'Quality ceiling, codec preference, merge after download, naming templates',
  '画质上限': 'Quality ceiling',
  '编码偏好': 'Codec preference',
  '下载完成后合并': 'Merge after download',
  '外挂 ffmpeg（可选）': 'External ffmpeg (optional)',
  '留空就用程序自带的那份。指一个目录可以换成你自己的完整版 ffmpeg —— '
      '自带那份是精简构建（约 10 MB），只能把视频流和音频流原样合起来，'
      '做不了转码、也没有 ffprobe。完整版能转码、烧字幕、看轨道信息。'
      '目录里直接放 ffmpeg.exe，或者放它的 bin 子目录，两种都认。':
      'Leave empty to use the bundled copy. Point it at a folder to use your own '
          'full ffmpeg instead — the bundled one is a trimmed build (~10 MB) that '
          'can only remux the video and audio streams together: no transcoding, '
          'no ffprobe. A full build can transcode, burn in subtitles, and inspect '
          'streams. Either keep ffmpeg.exe directly in that folder or in a bin '
          'subfolder; both are recognised.',
  '（空 = 用自带那份）': '(empty = use the bundled one)',
  '改回用自带那份': 'Switch back to the bundled copy',
  '跳过已下载的分 P': 'Skip parts already downloaded',
  '同一稿件的分 P 排在一起': 'Keep parts of one video together',
  '并发数': 'Concurrent downloads',
  '保存与命名': 'Save location and naming',
  '启用保存文件夹': 'Use save subfolder',
  '启用模版': 'Template preset',
  '这里是「上限」而不是保证：B 站会按你账号的实际权限（大会员、付费稿件）'
      '把拿不到的高阶档位直接裁掉，所以选了「1080P 60帧」也可能只下到 1080P。'
      '这是 B 站和本项目另两个模块最大的行为差异 —— 那里档位由平台返回的候选决定，'
      '这里还要多过一道账号权限，选高了不会报错，只会安静地退回能拿到的那一档。':
      'This is a ceiling, not a guarantee: Bilibili drops the tiers your account '
      'cannot reach (premium membership, paid content) before answering, so '
      'picking 1080P 60fps may still download plain 1080P. This is the biggest '
      'behavioral difference from the other two modules here — there the tier '
      'comes from whatever the platform returns, here it also passes an account '
      'permission check. Asking too high never errors, it quietly falls back to '
      'the best tier you can actually get.',
  '同一档画质 B 站通常同时给 H.264 / HEVC / AV1 三条流。选哪条不影响清晰度，'
      '只影响体积和播放器兼容性 —— HEVC / AV1 同画质更小，但老播放器与部分剪辑软件不认；'
      '「自动（兼容性优先）」挑哪边都能播的那条。这条同样只是偏好：稿件没有该编码的流时会退回其它编码，'
      '画质上限那套账号裁档的规则对这里一样成立。':
      'At the same quality Bilibili usually offers three streams: H.264, HEVC '
      'and AV1. Picking one does not change sharpness, only file size and '
      'playback compatibility — HEVC / AV1 are smaller at the same quality but '
      'older players and some editors refuse them. Auto (compatibility first) '
      'takes whichever plays everywhere. This is also only a preference: when '
      'the video has no stream in that codec it falls back to another one, and '
      'the account permission filter from the quality ceiling applies here too.',
  'B 站的视频流和音频流是分开的两个文件，下完是两个 .m4s，'
      '各自都不能单独播放 —— 必须先用 ffmpeg 合成一个 .mp4 才能看，所以默认开着。'
      '留这个开关只有一种用途：合并要用的 ffmpeg 被安全软件拦下时，'
      '先拿到原始流自己处理，总比什么都拿不到强。':
      'Bilibili video and audio are two separate files — you get two .m4s, and '
      'neither plays on its own. ffmpeg has to mux them into one .mp4 first, so '
      'this is on by default. The switch exists for exactly one case: when the '
      'bundled ffmpeg is blocked by security software, keeping the raw streams '
      'to process yourself still beats getting nothing usable.',
  '当前环境找不到可用的 ffmpeg，合并这一步会失败：'
      '下完只会得到两个不能单独播放的 .m4s 文件。':
      'No usable ffmpeg found — merging will fail and you would end up with two '
      '.m4s files that do not play on their own.',
  '按「BV 号 + 分 P 内容 ID」记账：下过的分 P 不再重下。'
      '记的是台账而不是磁盘上的文件，所以把文件移走、甚至删掉，也仍然算下过 —— '
      '想重下要么关掉这个开关，要么清掉记录。':
      'Booked by BV id plus part content id: parts already downloaded are queued '
      'again never. The ledger records the download, not the file on disk, so '
      'moving or deleting it still counts as downloaded — to re-download, either '
      'turn this off or clear the records.',
  '一个稿件的多个分 P 会占连续位置，跨稿件的才交错。关闭后严格按抓取顺序入队。':
      'Parts of one video take consecutive slots; only different videos '
      'interleave. When off, items are queued strictly in fetch order.',
  'aria2 同时下载的任务数上限（默认 4）。这是那一个下载进程的全局上限，'
      '不是只作用于 B 站的队列 —— 调大它，同时在下的别的内容也会一起挤这几个槽位。':
      'Maximum concurrent aria2 transfers (default 4). This caps the whole '
      'download process, not just the Bilibili queue — raising it lets other '
      'downloads compete for the same slots.',
  '模板变量 %CUSTOM_TEXT% 的输出内容，可用来给文件名加前缀、标注批次等。'
      '留空时这个变量就是空串。':
      'What %CUSTOM_TEXT% expands to — use it for a file name prefix, a batch '
      'mark and so on. Left empty, the variable becomes an empty string.',
  '例如：追番清单': 'e.g. Anime watchlist',
  'B 站下载存到哪个根目录、往下怎么建子文件夹、文件叫什么名字，都由下面这几项决定。'
      '可用变量都是 B 站语义的：%WORK_TITLE% 作品标题、%PART_TITLE% 分P标题、'
      '%P% 分P序号、%BVID% BV 号、%UP_NAME% UP 主昵称、%QUALITY% 画质、'
      '%CODEC% 编码格式等。':
      'Which root folder Bilibili downloads land in, what subfolders go under '
      'it and what the files are called all come from the options below. Every '
      'variable is Bilibili-flavoured: %WORK_TITLE% video title, %PART_TITLE% '
      'part title, %P% part number, %BVID% BV id, %UP_NAME% uploader name, '
      '%QUALITY% quality, %CODEC% codec.',
  '开启：按下面的「文件夹模板」建子目录再存；'
      '关闭：忽略文件夹模板，文件全部平铺在保存根目录里':
      'On: build subfolders from the folder template below. Off: ignore the '
      'folder template and lay every file in the save root.',
  '从现成组合里挑一套，一键填进下面两个模板框；之后仍可手动微调，'
      '改过之后这里会显示「自定义」。':
      'Pick a ready-made pair and it fills both template fields below in one '
      'go. You can still fine-tune them afterwards — once you do, this shows '
      'Custom.',
  '留空则直接存到保存目录下': 'Leave empty to save straight into the save folder',
  '「启用保存文件夹」已关闭 —— 文件全部平铺在保存目录下':
      'Use save subfolder is off — every file goes flat into the save folder',
  '提示：文件夹模板建议只用「作品 / UP 主」这一级的变量；'
      '%MEDIA_INDEX%、%EXT% 这类逐文件的变量会让每个文件各建一个文件夹。'
      '分 P 想挤进同一个目录就别在这里放 %P%。':
      'Tip: the folder template should only use video-level or uploader-level '
      'variables. Per-file ones like %MEDIA_INDEX% and %EXT% create a folder for '
      'every file. To keep all parts of one video in the same folder, leave %P% '
      'out of here.',
  '留空则不按模板命名 —— 兜底名字由下载层决定，点「填入默认」恢复':
      'Leave empty to skip template naming — the download layer picks the name; '
      'tap Use default to restore it',

  // ── B 站下载选项弹窗（widgets/bili_download_options_dialog.dart）──
  'AI 生成的那条语言码带 ai- 前缀，与人工字幕同名，只有前缀能分。': 'AI subtitles carry an ai- prefix; the display name is identical to human ones.',
  'MP4 兼容性最好；只有 MKV 装得下内封字幕轨。': 'MP4 plays anywhere; only MKV can carry embedded subtitle tracks.',
  'nfo 给媒体库读，会多取一次标签；json 是我们自己那份解析结果。': 'NFO is for media libraries (one extra tag request); JSON is our own parse result.',
  '一条都不选 = 不筛选，平台给几条取几条。': 'Select none to skip filtering and take whatever the platform offers.',
  '下载设置': 'Downloader',
  '下载选项': 'Download options',
  '不影响清晰度，只影响体积与播放器兼容性。': 'Does not change quality, only size and player compatibility.',
  '两族都是 ass 时会抢同一条字幕轨，这里定谁在前。': 'Both are ass tracks, so this decides which one goes first.',
  '人工字幕匿名一般拿不到；一条都没有时会在完成行上写出来。': 'Human subtitles are usually unavailable anonymously; nothing fetched is reported on the row.',
  '仅人工字幕': 'Human subtitles only',
  '元数据': 'Metadata',
  '关掉就留两条 .m4s 裸流，它们各自都不能单独播放。': 'Off keeps two raw .m4s streams, neither of which plays on its own.',
  '内封字幕轨': 'Embed subtitle track',
  '内封现在还差': 'Still missing to embed',
  '减少': 'Decrease',
  '只要这几种语言': 'Only these languages',
  '只限这一批的每条任务，0 = 不限。F 盘是 USB 盘时能避免下载把盘打满。': 'Per-task cap for this batch only; 0 = unlimited. Keeps a USB disk from saturating.',
  '同步为默认并下载': 'Sync as default & download',
  '同稿件分 P 排在一起': 'Keep parts of one video together',
  '填了它，%CUSTOM_TEXT% 才会展开出东西。': '%CUSTOM_TEXT% only expands when you fill this in.',
  '增加': 'Increase',
  '媒体设置': 'Media',
  '字体': 'Font',
  '字号': 'Font size',
  '字幕': 'Subtitles',
  '容器': 'Container',
  '封面': 'Cover',
  '底部边距': 'Bottom margin',
  '弹幕': 'Danmaku',
  '弹幕与字幕撞名时': 'When danmaku and subtitles collide',
  '弹幕字体': 'Danmaku font',
  '把 ass 作为一条字幕轨塞进成品，而不是只留侧文件。': 'Put the ass file into the output as a subtitle track, not just beside it.',
  '按「稿件 + 分 P」认，换画质重下也算已下载。': 'Matched by video + part; changing quality still counts as downloaded.',
  '按视频时间每 6 分钟一段取回，长稿件就是几十个请求，这里限了并发。': 'Fetched in 6-minute segments; long videos mean dozens of requests, so concurrency is capped.',
  '按默认开始下载': 'Start (defaults)',
  '是「上限」不是保证：B 站会按账号权限把拿不到的高阶档裁掉。': 'A ceiling, not a promise: Bilibili drops tiers your account cannot access.',
  '每条任务限速': 'Per-task limit',
  '章节': 'Chapters',
  '绝大多数稿件没有分段章节，没有时一个参数都不多加。': 'Most videos have no chapters; when there are none, nothing extra is passed to ffmpeg.',
  '自定义文本内容': 'Custom text',
  '跳过已下载': 'Skip downloaded',
  '附加文件': 'Extra files',
  '附加文件不影响成品：缺了哪样会写在那一行的完成提示上，不静默。': 'Extra files never block the main output; anything missing is written on the finished row.',
  '限速': 'Speed limit',

  // ── B 站批量下载页（lib/pages/bili_batch_page.dart）────────────────
  'B 站批量下载': 'Bilibili Batch',
  '先粘至少一条主页 / 合集 / 系列 / 收藏夹链接': 'Paste at least one profile, collection, series or favorite-folder link first',
  '批量结束：目标 {n} 个，认出稿件 {m} 条，提交 {q} 条下载': 'Batch finished: {n} targets, {m} videos found, {q} queued',
  '这个列表里一条本期能下的稿件都没有': 'This list has no video the current build can download',
  '{bvid} 没有可下载的分 P': '{bvid} has no downloadable part',
  '还没登录，拿不到自建收藏夹列表 —— 把收藏夹链接或那串 id 粘进来一样能下': 'Not signed in, so the folder list is unavailable - pasting a folder link or its id still works',
  '列表没取回来（登录态过期或被风控）—— 贴收藏夹链接或 id 一样能下': 'The folder list did not come back (session expired or rate-limited) - a folder link or id still works',
  '页面加载中…': 'Loading page...',
  '正在准备内嵌页面…': 'Preparing the embedded page...',
  '一行一个目标：UP 主主页、合集 / 系列链接、收藏夹链接或那串 id、单条稿件链接或 BV 号都认。': 'One target per line: a UP profile, a collection / series link, a favorite folder link or its id, or a single video link or BV id.',
  '把链接一行一条粘进来': 'Paste links, one per line',
  '每个列表最多下几条': 'Max videos per list',
  '多 P 稿件取全部 P': 'Take every part of multi-part videos',
  '默认只取第 1P：一个 20P 的合集全取就是几百条队列。': 'Part 1 only by default: a 20-part collection would otherwise queue hundreds of rows.',
  '这几行认不出来，已经跳过：{lines}': 'These lines were not recognized and were skipped: {lines}',
  '识别到 {n} 个目标': '{n} targets recognized',
  '{n} 行认不出来': '{n} lines not recognized',
  '{n} 行超出上限': '{n} lines over the limit',
  '取列表中…': 'Loading folders...',
  '列出我的自建收藏夹': 'List my folders',
  '下拉里是「我建的」收藏夹；别人的收藏夹请贴链接': 'The dropdown only holds folders you created; for a shared folder paste its link',
  '选一个自建收藏夹加进目标': 'Pick a folder to add to the targets',
  '已把「{name}」加进目标': 'Added {name} to the targets',
  '「{name}」已经在目标里了': '{name} is already in the targets',
  '目标 {done}/{total}　认出 {m} 条　提交 {q} 条　跳过不支持 {u} 条': '{done}/{total} targets  {m} found  {q} queued  {u} unsupported skipped',
  '稿件 {n} 条': '{n} videos',
  '已下过 {n}': '{n} already downloaded',
  '不支持 {n}': '{n} unsupported',
  '截掉 {n}': '{n} cut off',
  '展开短链': 'Expanding short link',
  '入队中': 'Queuing',
  '批量下载': 'Batch Download',
  '取列表': 'Reading the list',
  '失败 {n}': '{n} failed',
  '提交 {n}': '{n} queued',
  '开始批量': 'Start batch',
  '未检测到 Edge WebView2 运行时。\n这一页的「UP 主主页投稿」与「我的自建收藏夹」要用到它；合集 / 系列 / 贴收藏夹 id 这几支仍然可以用纯接口那条路。': 'Edge WebView2 runtime was not detected.\nThis page needs it for "UP profile posts" and "my favorite folders"; collections, series and a pasted folder id still work through the plain API path.',

  // ── 页头副标题（S9a 纯文字页头，2026-10-13）─────────────────────
  //
  // 文案逐条取自预览稿 `index.html` PAGES 表的 `s:` 字段（:360-724）。
  // 这些是**页面级副标题**，与导航标签（'Downloads' / 'Auto Tasks'）不同：
  // 更长、更描述性，侧边栏不会用到，所以不受那条「导航标签刻意收短」
  // 的约束，按语义直译即可。
  '版本、许可与本机环境': 'Version, licenses and local environment',
  '按名单批量跑': 'Batch-run a user list',
  '主页 / 合集 / 系列 / 收藏夹': 'Profile / collections / series / favorites',
  '左边浏览，右边抓取': 'Browse on the left, grab on the right',
  '总览 · 快捷入口 · 最近活动': 'Overview · shortcuts · recent activity',
  '抖音自动下载': 'Douyin Auto Download',
  '按目标批量滚动抓取': 'Batch-scroll targets',
  'X 主页': 'X Home',
};
