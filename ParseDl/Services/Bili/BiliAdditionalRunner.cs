using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ParseDl.Services.Bili;

/// <summary>一次附加文件跑完的结果 —— 对齐 Flutter 版 bili_additional.dart 的 BiliAdditionalOutcome。</summary>
public sealed record BiliAdditionalOutcome(
    IReadOnlyList<BiliEmbeddedTrack> Tracks,
    IReadOnlyList<string> Written,
    IReadOnlyList<string> Missing,
    string? ChapterFileName)
{
    public static readonly BiliAdditionalOutcome None = new(
        Array.Empty<BiliEmbeddedTrack>(), Array.Empty<string>(), Array.Empty<string>(), null);

    public bool HasAnything => Tracks.Count > 0 || Written.Count > 0 || ChapterFileName is not null;
}

/// <summary>
/// 附加文件产出 —— 弹幕 / 字幕 / 封面 / 章节 / 元数据，从 Flutter 版
/// lib/services/bili_additional_runner.dart（353 行）移植。
///
/// 一条纪律：**附加文件不走 aria2**（它们都是几十 KB 的小文件，走 aria2 要新增
/// 一类 gid 配对，带凭据的那几种还会撞上「per-task header 被 --save-session
/// 明文写盘」那条红线）。
///
/// 主产物完好就算下载成功；但「用户勾了却没拿到」的东西**绝不能只写进日志**，
/// 要如实进 Missing 让界面列出来（接口没返回、语言筛完剩零条、网络失败都算）。
/// </summary>
public static class BiliAdditionalRunner
{
    public static async Task<BiliAdditionalOutcome> ProduceAsync(
        BiliApi api,
        BiliConfig cfg,
        string saveDir,
        string outBase,
        BiliVideoInfo info,
        long cid,
        string pageTitle,
        int pageIndex,
        CancellationToken ct = default)
    {
        if (!cfg.SaveDanmaku && !cfg.SaveSubtitle && !cfg.SaveCover &&
            !cfg.SaveChapter && !cfg.SaveMetadata)
            return BiliAdditionalOutcome.None;

        Directory.CreateDirectory(saveDir);
        var written = new List<string>();
        var missing = new List<string>();
        var tracks = new List<BiliEmbeddedTrack>();
        string? chapterFile = null;

        // ── 一次取回 v2：章节 view_points 与字幕列表都在这里面 ──────────
        JsonElement? v2Data = null;
        if (cfg.SaveChapter || cfg.SaveSubtitle)
        {
            try
            {
                v2Data = await api.GetSignedDataAsync("/x/player/wbi/v2", new Dictionary<string, string?>
                {
                    ["bvid"] = info.Bvid,
                    ["cid"] = cid.ToString(),
                }, ct);
            }
            catch (Exception ex)
            {
                if (cfg.SaveChapter) missing.Add("章节（取 view_points 失败：" + ex.Message + "）");
                if (cfg.SaveSubtitle) missing.Add("字幕（取字幕列表失败：" + ex.Message + "）");
            }
        }

        // ── 弹幕 ────────────────────────────────────────────────────
        if (cfg.SaveDanmaku)
        {
            try
            {
                var dms = await BiliDanmakuService.FetchAllAsync(api, cid, 100, ct);
                if (dms.Count == 0)
                {
                    missing.Add("弹幕（接口返回空，可能是稿件无弹幕或需要登录）");
                }
                else
                {
                    if (cfg.DanmakuFormat == BiliDanmakuFormat.Ass)
                    {
                        // **ASS 是枚举里的第一项（默认值）**（2026-10-29 补）：
                        // 之前这里只有 Xml / Json 两个分支，选 ASS 会一个文件都不生成 ——
                        // 用户以为「弹幕没下下来」，其实是代码里根本没这条分支。
                        var name = BiliAdditional.AdditionalName(outBase, "弹幕", null, "ass");
                        var ass = BiliDanmakuAss.Build(
                            dms,
                            Math.Max(1, cfg.DanmakuFontSize),
                            Math.Max(0, cfg.DanmakuMarginV),
                            Math.Clamp(cfg.DanmakuOpacity, 0, 100) / 100.0,
                            pageTitle + (info.Pages.Count > 1 ? " P" + (pageIndex + 1) : ""));
                        await File.WriteAllTextAsync(Path.Combine(saveDir, name),
                            ass.Ass, System.Text.Encoding.UTF8, ct);
                        written.Add(name);
                    }
                    else if (cfg.DanmakuFormat == BiliDanmakuFormat.Xml)
                    {
                        var name = BiliAdditional.AdditionalName(outBase, "弹幕", null, "xml");
                        await File.WriteAllTextAsync(Path.Combine(saveDir, name),
                            BiliDanmakuService.ToXml(dms, cid), System.Text.Encoding.UTF8, ct);
                        written.Add(name);
                    }
                    else if (cfg.DanmakuFormat == BiliDanmakuFormat.Json)
                    {
                        var name = BiliAdditional.AdditionalName(outBase, "弹幕", null, "json");
                        var json = JsonSerializer.Serialize(dms, new JsonSerializerOptions
                        {
                            WriteIndented = true,
                            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
                        });
                        await File.WriteAllTextAsync(Path.Combine(saveDir, name), json,
                            System.Text.Encoding.UTF8, ct);
                        written.Add(name);
                    }
                    else
                    {
                        // ASS 是唯一能内封的弹幕格式。
                        var name = BiliAdditional.AdditionalName(outBase, "弹幕", "中文", "ass");
                        await File.WriteAllTextAsync(Path.Combine(saveDir, name),
                            BiliAdditional.DanmakuToAss(dms, info.Title), System.Text.Encoding.UTF8, ct);
                        written.Add(name);
                        tracks.Add(new BiliEmbeddedTrack(name, "弹幕", "chi", true));
                    }
                }
            }
            catch (Exception ex)
            {
                missing.Add("弹幕（" + ex.Message + "）");
            }
        }

        // ── 字幕 ────────────────────────────────────────────────────
        if (cfg.SaveSubtitle)
        {
            try
            {
                var subs = SubtitleEntriesOf(v2Data);
                if (subs.Count == 0)
                {
                    missing.Add("字幕（接口没给字幕；字幕是登录用户才有的权益）");
                }
                else
                {
                    var saved = 0;
                    foreach (var (lan, label, url) in subs)
                    {
                        if (ct.IsCancellationRequested) break;
                        try
                        {
                            var sub = await BiliSubtitleService.FetchAsync(url, lan, label, ct);
                            if (sub.Cues.Count == 0) continue;
                            var ext = cfg.SubtitleFormat switch
                            {
                                BiliSubtitleFormat.Ass => "ass",
                                BiliSubtitleFormat.Txt => "txt",
                                _ => "srt",
                            };
                            var body = cfg.SubtitleFormat switch
                            {
                                BiliSubtitleFormat.Ass => BiliAdditional.SubtitleToAss(sub.Cues, label),
                                BiliSubtitleFormat.Txt => BiliSubtitleService.ToPlainText(sub.Cues),
                                _ => BiliSubtitleService.ToSrt(sub.Cues),
                            };
                            var name = BiliAdditional.AdditionalName(outBase, "字幕", lan, ext);
                            await File.WriteAllTextAsync(Path.Combine(saveDir, name), body,
                                System.Text.Encoding.UTF8, ct);
                            written.Add(name);
                            saved++;
                            if (cfg.SubtitleFormat == BiliSubtitleFormat.Ass)
                            {
                                // AI 字幕必须在这一步就标出来：B 站给的人工字幕与 AI 字幕
                                // 的 lan_doc 完全同名，只有 lan 里的 ai- 前缀能区分。
                                var title = lan.StartsWith("ai-", StringComparison.OrdinalIgnoreCase)
                                    ? label + "（AI）" : label;
                                tracks.Add(new BiliEmbeddedTrack(
                                    name, title, BiliAdditional.Iso639FromLan(lan), false));
                            }
                        }
                        catch
                        {
                            // 单条字幕失败不算整体失败，但记进 missing
                            missing.Add("字幕 " + label + "（下载或解析失败）");
                        }
                    }
                    if (saved == 0) missing.Add("字幕（取到的都解析为空）");
                }
            }
            catch (Exception ex)
            {
                missing.Add("字幕（" + ex.Message + "）");
            }
        }

        // ── 封面 ────────────────────────────────────────────────────
        if (cfg.SaveCover)
        {
            var name = await BiliAdditional.WriteCoverAsync(saveDir, outBase, info.Cover, cfg.CoverFormat, 3, ct);
            if (name is null) missing.Add("封面（拉取失败或稿件没有封面）");
            else written.Add(name);
        }

        // ── 章节 ────────────────────────────────────────────────────
        if (cfg.SaveChapter)
        {
            var points = ViewPointsOf(v2Data);
            var meta = BiliAdditional.ChaptersToFfmetadata(points, info.DurationSec);
            if (meta is null)
            {
                // view_points 空是**常态**（绝大多数稿件没有分段章节），
                // 这时不该报「没拿到」，也不该多带一个输入。
            }
            else
            {
                chapterFile = BiliAdditional.ChapterScratchName(outBase);
                await File.WriteAllTextAsync(Path.Combine(saveDir, chapterFile), meta,
                    System.Text.Encoding.UTF8, ct);
            }
        }

        // ── 元数据 ──────────────────────────────────────────────────
        if (cfg.SaveMetadata)
        {
            try
            {
                var ext = cfg.MetadataFormat == BiliMetadataFormat.Nfo ? "nfo" : "json";
                var name = BiliAdditional.AdditionalName(outBase, "元数据", null, ext);
                string body;
                if (cfg.MetadataFormat == BiliMetadataFormat.Nfo)
                {
                    var tags = await FetchTagsAsync(api, info.Bvid, ct);
                    body = BiliAdditional.MetadataToNfo(
                        ParseView(info.RawJson), tags, pageTitle, pageIndex);
                }
                else
                {
                    // json 档是「原样存一份」，不做过滤与排序 —— 它的用途就是事后
                    // 能对上是哪个响应，替它挑字段反而破坏了用途。
                    body = string.IsNullOrWhiteSpace(info.RawJson) ? "{}" : info.RawJson;
                }
                await File.WriteAllTextAsync(Path.Combine(saveDir, name), body,
                    System.Text.Encoding.UTF8, ct);
                written.Add(name);
            }
            catch (Exception ex)
            {
                missing.Add("元数据（" + ex.Message + "）");
            }
        }

        var ordered = BiliAdditional.OrderTracks(tracks, cfg.TrackPriority);
        return new BiliAdditionalOutcome(ordered, written, missing, chapterFile);
    }

    /// <summary>v2 的 subtitle.subtitles[] → (lan, label, url)。</summary>
    private static List<(string Lan, string Label, string Url)> SubtitleEntriesOf(JsonElement? v2)
    {
        var list = new List<(string, string, string)>();
        if (v2 is not JsonElement root) return list;
        if (!root.TryGetProperty("subtitle", out var sub) ||
            !sub.TryGetProperty("subtitles", out var arr) ||
            arr.ValueKind != JsonValueKind.Array) return list;

        foreach (var s in arr.EnumerateArray())
        {
            var lan = s.TryGetProperty("lan", out var l) ? l.GetString() ?? "" : "";
            var label = s.TryGetProperty("lan_doc", out var ld) ? ld.GetString() ?? lan : lan;
            var url = s.TryGetProperty("subtitle_url", out var u) ? u.GetString() ?? "" : "";
            if (string.IsNullOrEmpty(url)) continue;
            if (url.StartsWith("//")) url = "https:" + url;
            list.Add((lan, label, url));
        }
        return list;
    }

    private static List<JsonElement> ViewPointsOf(JsonElement? v2)
    {
        var list = new List<JsonElement>();
        if (v2 is not JsonElement root) return list;
        if (!root.TryGetProperty("view_points", out var vp) || vp.ValueKind != JsonValueKind.Array)
            return list;
        foreach (var e in vp.EnumerateArray()) list.Add(e.Clone());
        return list;
    }

    private static JsonElement ParseView(string rawJson)
    {
        if (string.IsNullOrWhiteSpace(rawJson)) return default;
        try
        {
            using var doc = JsonDocument.Parse(rawJson);
            return doc.RootElement.Clone();
        }
        catch
        {
            return default;
        }
    }

    private static async Task<List<string>> FetchTagsAsync(BiliApi api, string bvid, CancellationToken ct)
    {
        try
        {
            var data = await api.GetDataPublicAsync(
                "/x/web-interface/view/detail/tag?bvid=" + Uri.EscapeDataString(bvid), ct);
            return BiliAdditional.TagsFromData(data);
        }
        catch
        {
            return new List<string>();
        }
    }
}
