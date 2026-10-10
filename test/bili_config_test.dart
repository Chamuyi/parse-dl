import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_config.dart';
import 'package:parse_dl/models/bili_meta.dart';
import 'package:parse_dl/models/douyin_config.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/services/file_name_template.dart';

void main() {
  group('画质与编码枚举', () {
    test('画质上限与 B 站 qn 对齐', () {
      expect(BiliQuality.q360.qn, 16);
      expect(BiliQuality.q480.qn, 32);
      expect(BiliQuality.q720.qn, 64);
      expect(BiliQuality.q1080.qn, 80);
      expect(BiliQuality.q1080p60.qn, 116);
      expect(BiliQuality.q4k.qn, 120);
      expect(BiliQuality.q8k.qn, 127);
      // 「最高可用」不是一个档位，而是放行到 8K 让平台按账号权限裁
      expect(BiliQuality.highest.qn, 127);
    });

    test('id 认不出来一律回默认，不给 null 也不抛', () {
      expect(BiliQuality.fromId('8k'), BiliQuality.q8k);
      expect(BiliQuality.fromId('2160p'), BiliQuality.highest);
      expect(BiliQuality.fromId(null), BiliQuality.highest);
      expect(BiliCodec.fromId('av1'), BiliCodec.av1);
      expect(BiliCodec.fromId('vp9'), BiliCodec.auto);
      expect(BiliCodec.fromId(null), BiliCodec.auto);
    });

    test('id 全仓唯一（进了 settings.json 就是主键）', () {
      for (final ids in [
        BiliQuality.values.map((e) => e.id),
        BiliCodec.values.map((e) => e.id),
      ]) {
        expect(ids.toSet().length, ids.length);
      }
    });
  });

  group('BiliConfig 持久化', () {
    test('默认值 round-trip 一致', () {
      final c = BiliConfig();
      final back = BiliConfig.fromJson(
        jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>,
      );
      expect(back.quality, c.quality);
      expect(back.codec, c.codec);
      expect(back.mergeAfterDownload, c.mergeAfterDownload);
      expect(back.skipDownloaded, c.skipDownloaded);
      expect(back.groupByWork, c.groupByWork);
      expect(back.concurrency, c.concurrency);
      expect(back.customText, c.customText);
      expect(back.saveDirBase, c.saveDirBase);
      expect(back.enableSaveFolder, c.enableSaveFolder);
      expect(back.dirTemplate, c.dirTemplate);
      expect(back.fileNameTemplate, c.fileNameTemplate);
      expect(back.isDefault, isTrue);
    });

    test('缺字段走默认值（老配置里没有 bili 块也能起来）', () {
      final s = Settings.fromJson({});
      expect(s.bili.quality, BiliQuality.highest);
      expect(s.bili.fileNameTemplate, kBiliDefaultFileNameTemplate);
      expect(s.bili.isDefault, isTrue);
    });

    test('字符串型的脏值按字段退回默认；多出来的键忽略', () {
      final c = BiliConfig.fromJson({
        'quality': 'nonsense',
        'codec': 'vp9',
        'whatever': true,
      });
      expect(c.quality, BiliQuality.highest);
      expect(c.codec, BiliCodec.auto);
    });

    test('类型写错的值会让整份设置退回默认（既有行为，bili 不另开一套）', () {
      // `BiliConfig.fromJson` 用的是 `as String?` / `as bool?`，脏类型会抛；
      // 兜底在 `Settings.decode` 那一层 —— 与 DouyinConfig 完全同构，
      // 所以「手工改坏 settings.json」的代价是全部设置回默认，而不是只丢一项。
      expect(() => BiliConfig.fromJson({'codec': 123}), throwsA(anything));
      final broken = Settings.decode(
        '{"state":{"bili":{"codec":123},"douyin":{"source":"h265"}},"version":3}',
      );
      expect(broken.bili.codec, BiliCodec.auto);
      expect(broken.douyin.source, DouyinSource.defaultAddr);
    });

    test('bili 块进了 Settings 的 JSON，键名稳定', () {
      final s = Settings();
      s.bili.quality = BiliQuality.q720;
      final j = jsonDecode(s.encode()) as Map<String, dynamic>;
      expect(j['version'], 3);
      expect(((j['state'] as Map)['bili'] as Map)['quality'], '720p');
      // 读回来还是 720p
      expect(Settings.decode(s.encode()).bili.quality, BiliQuality.q720);
    });

    test('配置里**不许有 cookie / SESSDATA / buvid 这类登录态字段**', () {
      // 这是计划里 D4 的落点：B 站凭据只活在运行时，一次落盘就等于把账号
      // 写进一个会被同步、被备份的普通文本文件。用 JSON 的键名来钉死这条。
      final keys = Settings().bili.toJson().keys.toSet();
      for (final forbidden in [
        'cookie',
        'sessdata',
        'buvid',
        'biliTicket',
        'token',
        'auth',
      ]) {
        expect(
          keys.any((k) => k.toLowerCase().contains(forbidden.toLowerCase())),
          isFalse,
          reason: 'BiliConfig 里出现了登录态字段：$forbidden',
        );
      }
      expect(keys, BiliConfig().toJson().keys.toList());
    });

    test('改过任何一项，isDefault 就翻 false', () {
      expect(BiliConfig().isDefault, isTrue);
      expect((BiliConfig()..codec = BiliCodec.av1).isDefault, isFalse);
      expect((BiliConfig()..concurrency = 2).isDefault, isFalse);
      expect((BiliConfig()..skipDownloaded = false).isDefault, isFalse);
    });
  });

  group('默认模板与预设', () {
    test('默认文件名模板：多 P 出 P03-，单 P 整段连字面量一起消失', () {
      expect(
        resolveVariables(kBiliDefaultFileNameTemplate, biliExampleMedia()),
        'P03-第3P 冬天-1080P60-AV1.m4s',
      );
      final single = biliExampleMedia().copyWith(
        bili: const BiliMeta(
          workTitle: '把一年的海边拍成十二段',
          partTitle: '把一年的海边拍成十二段',
          bvid: 'BV1y4411o7Kp',
          partTotal: 1,
          qualityLabel: '1080P60',
          codecLabel: 'AV1',
        ),
      );
      expect(
        resolveVariables(kBiliDefaultFileNameTemplate, single),
        '把一年的海边拍成十二段-1080P60-AV1.m4s',
        reason: '单 P 不该出现 P0 / P00 —— 参照实现踩过的坑',
      );
    });

    test('默认文件夹模板：一个稿件一个目录', () {
      expect(
        resolveVariables(kBiliDefaultDirTemplate, biliExampleMedia()),
        '把一年的海边拍成十二段',
      );
    });

    test('每个预设的两条模板都不是空串或 null', () {
      for (final p in kBiliTemplatePresets) {
        expect(p.id.isNotEmpty, isTrue);
        expect(p.label.isNotEmpty, isTrue);
        // dirTemplate 允许为空 —— 那是「全部平铺」这个预设的语义
        expect(p.fileNameTemplate.contains('%'), isTrue);
      }
      expect(
        kBiliTemplatePresets.map((p) => p.id).toSet().length,
        kBiliTemplatePresets.length,
      );
      expect(kBiliTemplatePresets.map((p) => p.id), isNot(contains(kBiliCustomPresetId)));
    });

    test('第一个预设与默认值完全一致（初始状态下拉停得住）', () {
      final c = BiliConfig();
      final first = kBiliTemplatePresets.first;
      expect(c.dirTemplate, first.dirTemplate);
      expect(c.fileNameTemplate, first.fileNameTemplate);
    });
  });
}
