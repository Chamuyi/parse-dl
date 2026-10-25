using System;
using System.IO;

namespace ParseDl.Services.Bili;

/// <summary>
/// 入队前的落目录计算 —— 把「保存目录 + 文件夹模板」算成一个绝对路径。
///
/// 为什么单独抽出来：解析页与批量页都要算，而这条规则里有一条容易写错的地方
/// （文件夹模板渲染完可能带非法字符、可能是空串、可能多级），
/// 两处各写一遍迟早会漂。
/// </summary>
public static class BiliEnqueue
{
    /// <summary>
    /// 算出这条分P 的落盘目录。
    ///  - 保存目录为空 → 用全局默认（Aria2Engine.DefaultDir）；
    ///  - 「启用保存文件夹」关 → 直接平铺在保存目录下；
    ///  - 文件夹模板渲染为空 → 同样平铺（不是建一个叫空串的目录）。
    /// </summary>
    public static string ResolveSaveDir(
        BiliConfig cfg, string saveDir, BiliVideoInfo info, BiliPart part,
        BiliStreamPair pair, BiliPlayInfo play)
    {
        var root = string.IsNullOrWhiteSpace(saveDir) ? Aria2Engine.DefaultDir() : saveDir;
        var tpl = cfg.EffectiveDirTemplate;
        if (string.IsNullOrWhiteSpace(tpl)) return root;

        var ctx = new BiliTemplate.Context
        {
            WorkTitle = info.Title,
            PartTitle = part.Title,
            // 文件夹模板里放 %P% 会让每个分P 各建一个目录 —— 原项目的提示也是这么说的，
            // 但用户真写了就照他的写，不在这里偷偷改。
            Part = info.Pages.Count > 1 ? part.Page : 0,
            PartTotal = info.Pages.Count,
            Bvid = info.Bvid,
            Aid = info.Aid,
            Cid = long.TryParse(part.Cid, out var c) ? c : 0,
            UpName = info.OwnerName,
            UpMid = info.OwnerMid,
            Quality = pair.Video?.QualityLabel ?? "",
            Codec = pair.VideoCodec,
            CustomText = cfg.CustomText,
            DurationSec = part.DurationSec,
        };
        var rendered = BiliTemplate.Render(tpl, ctx);

        // 逐段净化：模板可能写成 A/B 两级，按分隔符拆开逐段清，
        // 别让一段里的非法字符把整条路径毁掉
        var segments = rendered.Split(new[] { '/', '\\' }, StringSplitOptions.RemoveEmptyEntries);
        var dir = root;
        foreach (var seg in segments)
        {
            var clean = BiliTemplate.Sanitize(seg);
            if (clean.Length == 0) continue;
            dir = Path.Combine(dir, clean);
        }
        return dir;
    }
}
