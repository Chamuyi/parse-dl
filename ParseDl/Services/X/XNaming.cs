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
    
        /// <summary>模板上下文（文件名与目录共用，保证两处变量取值完全一致）。</summary>
        public static TemplateContext BuildContext(XPost p, int mediaIndex)
        {
            var m = p.Media[mediaIndex];
            var ext = m.Type is "video" or "gif" ? "mp4" : "jpg";
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
            };
        }
    
        public static string NameFor(XPost p, int mediaIndex)
        {
            var m = p.Media[mediaIndex];
            var settings = AppSettings.Instance.ForModule("x");
            var tpl = string.IsNullOrWhiteSpace(settings.FileNameTemplate)
                ? "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%"
                : settings.FileNameTemplate;
    
            var ext = m.Type is "video" or "gif" ? "mp4" : "jpg";
            var ctx = BuildContext(p, mediaIndex);
    
            var name = FileNameTemplate.UnicodeFilenamify(FileNameTemplate.Resolve(tpl, ctx));
            if (string.IsNullOrWhiteSpace(name)) name = p.Id + "_" + (mediaIndex + 1);
    
            // 模板里带 %EXT% 时名字已含扩展名，别再加一遍（会变成 x.jpg.jpg）
            var dotExt = "." + ext;
            if (!name.EndsWith(dotExt, StringComparison.OrdinalIgnoreCase)) name += dotExt;
            return name;
        }
}