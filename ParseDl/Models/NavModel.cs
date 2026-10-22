using System.Collections.Generic;

namespace ParseDl.Models;

/// <summary>一个导航项。</summary>
public sealed record NavItem(string Id, string Label, string Glyph);

/// <summary>
/// 一个下载模块：侧边栏里一个可展开的入口 + 它下面的功能页。
/// 三个模块（X / 抖音 / B 站）在功能与设置层面都保持独立。
/// </summary>
public sealed record NavGroup(
    string Id,
    string Label,
    string Glyph,
    string Badge,
    IReadOnlyList<NavItem> Children);

/// <summary>
/// 导航结构 —— 与 Flutter 版 lib/widgets/nav_items.dart 一一对应。
/// 改这里要同步改那边（如果 Flutter 版还留着）或至少保持一致的信息架构。
/// </summary>
public static class NavModel
{
    /// <summary>置顶项：总览。软件打开就落在这里。</summary>
    public static readonly IReadOnlyList<NavItem> Primary = new[]
    {
        new NavItem("dashboard", "总览", "\uE80F"),
    };

    /// <summary>三个下载模块。数组顺序即侧边栏顺序。</summary>
    public static readonly IReadOnlyList<NavGroup> Groups = new[]
    {
        new NavGroup("x", "X 下载", "\uE896", "X", new[]
        {
            new NavItem("home", "主页", "\uE80F"),
            new NavItem("download-management", "下载管理", "\uE896"),
            new NavItem("auto-task", "自动执行", "\uE945"),
            new NavItem("x-settings", "X 下载设置", "\uE9E9"),
        }),
        new NavGroup("douyin", "抖音解析下载", "\uE8D6", "抖", new[]
        {
            new NavItem("douyin", "解析下载", "\uE768"),
            new NavItem("douyin-downloads", "下载管理", "\uE896"),
            new NavItem("douyin-auto", "自动下载", "\uE945"),
            new NavItem("douyin-settings", "抖音设置", "\uE9E9"),
        }),
        new NavGroup("bili", "B 站下载", "\uE7F4", "B", new[]
        {
            new NavItem("bili", "解析下载", "\uE768"),
            new NavItem("bili-batch", "批量下载", "\uE8EF"),
            new NavItem("bili-downloads", "下载管理", "\uE896"),
            new NavItem("bili-settings", "B 站设置", "\uE9E9"),
        }),
    };

    /// <summary>全局项：排在三个模块下面。</summary>
    public static readonly IReadOnlyList<NavItem> Standalone = new[]
    {
        new NavItem("settings", "全局设置", "\uE713"),
        new NavItem("about", "关于", "\uE946"),
    };
}
