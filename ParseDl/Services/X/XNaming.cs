using System;
using System.Linq;
using ParseDl.Services;

namespace ParseDl.Services.X;

/// <summary>
/// X 媒体的「目录 / 文件名」计算 —— 从 XHomePage 抽出来，
/// 让主页与「任务创建中」后台队列（<see cref="CreationTaskStore"/>）**共用同一套规则**。
///
/// 不抽出来的后果：两处各写一份模板解析，改了一处另一处忘了，
/// 同一个作品从主页下和从创建任务下会落到**不同目录/不同文件名**。
/// </summary>
public static class XNaming
{
    public static string? DirFor(XPost p, int mediaIndex)
        {
            var settings = AppSettings.Instance.ForModule("x");
            var baseDir = string.IsNullOrWhiteSpace(settings.SaveDir) ? null : settings.SaveDir;
    
            var tpl = settings.DirTemplate ?? "";
            if (string.IsNullOrWhiteSpace(tpl)) return baseDir;
    
            var sub = FileNameTemplate.Resolve(tpl, BuildContext(p, mediaIndex)).Trim();
            if (sub.Length == 0) return baseDir;
    
            // 模板里的斜杠表示多级目录（如 %USER_SCREEN_NAME%/%POST_TIME,d=1%）
            var parts = sub.Split(new[] { (char)47, (char)92 }, StringSplitOptions.RemoveEmptyEntries)
                .Select(s => FileNameTemplate.UnicodeFilenamify(s).Trim())
                .Where(s => s.Length > 0)
                .ToArray();
            if (parts.Length == 0) return baseDir;
    
            var root = baseDir ?? Aria2Engine.DefaultDir();
            var full = System.IO.Path.Combine(new[] { root }.Concat(parts).ToArray());
            try { System.IO.Directory.CreateDirectory(full); } catch { return baseDir; }
            return full;
        }
    
        /// <summary>
        /// 扩展名（不含点）—— **与 Flutter 版逐条对齐**（2026-10-31 修）。
        ///
        /// 旧实现是 `m.Type is "video" or "gif" ? "mp4" : "jpg"`，图片一律 jpg。
        /// 但 Flutter 版的 `%EXT%` 是**先看下载链接的真实后缀**：
        ///   `url.split('?').first.split('.').last` 若匹配 `^[A-Za-z0-9]{1,5}$` 就取它，
        ///   否则退回 `Media.extension`。
        /// X 的图片 URL 是 `https://pbs.twimg.com/media/<id>.png?name=orig`，
        /// 于是 **png 图会落成 .png**（实测 D:\\下载目录 下有 851 个 .png 就是这么来的）。
        /// 两版不一致会让同一张图一边叫 x.png、一边叫 x.jpg，文件名对不上。
        /// </summary>
        public static string ExtensionFor(XMedia m)
        {
            // ① 先看下载链接的真实后缀（与 Flutter EXT 的第一条分支完全一致）
            var url = m.Url ?? "";
            if (url.Length > 0)
            {
                var noQuery = url.Split((char)63)[0];          // 去掉 ?query
                var dot = noQuery.LastIndexOf((char)46);
                if (dot >= 0)
                {
                    var tail = noQuery[(dot + 1)..];
                    // 注意：**不转小写**。Flutter 那边 `return '.$tail'` 是原样返回，
                    // 转了小写会让 `ABC.PNG` 这种变成 .png，与旧版产出对不上。
                    if (tail.Length is >= 1 and <= 5 && tail.All(char.IsAsciiLetterOrDigit))
                        return tail;
                }
            }
            // ② 退回按媒体类型（对齐 Media.extension）
            return m.Type switch
            {
                "video" => "mp4",
                "audio" => "mp3",
                "gif" => "gif",
                _ => "jpg",
            };
        }

        /// <summary>模板上下文（文件名与目录共用，保证两处变量取值完全一致）。</summary>
        public static TemplateContext BuildContext(XPost p, int mediaIndex)
        {
            var m = p.Media[mediaIndex];
            var ext = ExtensionFor(m);
            return new TemplateContext
            {
                PostId = p.Id,
                PostTime = p.CreatedAt,
                UserId = p.UserId,
                UserName = p.UserName,
                UserScreenName = p.UserScreenName,
                MediaId = m.Id,
                MediaIndex = mediaIndex + 1,
                MediaCount = p.Media.Count,
                MediaWidth = m.Width,
                MediaHeight = m.Height,
                MediaType = m.Type,
                Extension = ext,
                Content = p.Text,
                Tags = p.Tags,
            };
        }
    
        public static string NameFor(XPost p, int mediaIndex)
        {
            var m = p.Media[mediaIndex];
            var settings = AppSettings.Instance.ForModule("x");
            var tpl = string.IsNullOrWhiteSpace(settings.FileNameTemplate)
                ? "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%"
                : settings.FileNameTemplate;
    
            var ext = ExtensionFor(m);
            var ctx = BuildContext(p, mediaIndex);
    
            var name = FileNameTemplate.UnicodeFilenamify(FileNameTemplate.Resolve(tpl, ctx));
            if (string.IsNullOrWhiteSpace(name)) name = p.Id + "_" + (mediaIndex + 1);
    
            // 模板里带 %EXT% 时名字已含扩展名，别再加一遍（会变成 x.jpg.jpg）
            var dotExt = "." + ext;
            if (!name.EndsWith(dotExt, StringComparison.OrdinalIgnoreCase)) name += dotExt;
            return name;
        }
}