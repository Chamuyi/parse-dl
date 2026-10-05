import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/douyin_config.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/settings_store.dart';

/// 抖音设置的枚举映射、序列化与持久化。
///
/// 重点在**枚举 id 是稳定字面量** —— 这些 id 进了 `settings.json`，
/// 改一个字母就会让老用户的配置回落成默认值。
void main() {
  group('枚举 id 是稳定字面量', () {
    test('下载源 6 档', () {
      expect(DouyinSource.values.map((e) => e.id).toList(), [
        'default',
        'h264',
        'h265',
        'quality_first',
        'quality_first_bytevc1',
        'audio_only',
      ]);
      for (final e in DouyinSource.values) {
        expect(DouyinSource.fromId(e.id), e);
      }
    });

    test('质量优先策略 4 档', () {
      expect(DouyinQualityMode.values.map((e) => e.id).toList(),
          ['auto', 'resolution', 'bitrate', 'fps']);
      for (final e in DouyinQualityMode.values) {
        expect(DouyinQualityMode.fromId(e.id), e);
      }
    });

    test('图片格式 2 档', () {
      expect(DouyinImageFormat.values.map((e) => e.id).toList(), ['webp', 'jpg']);
      for (final e in DouyinImageFormat.values) {
        expect(DouyinImageFormat.fromId(e.id), e);
      }
    });

    test('未知 / 缺失 id 一律回落默认值（不抛异常）', () {
      expect(DouyinSource.fromId('nope'), DouyinSource.defaultAddr);
      expect(DouyinSource.fromId(null), DouyinSource.defaultAddr);
      expect(DouyinQualityMode.fromId('nope'), DouyinQualityMode.auto);
      expect(DouyinImageFormat.fromId('nope'), DouyinImageFormat.keep);
    });

    test('只有两个「质量优先」档才需要质量策略下拉', () {
      expect(DouyinSource.qualityFirst.needsQualityMode, isTrue);
      expect(DouyinSource.qualityFirstBytevc1.needsQualityMode, isTrue);
      expect(DouyinSource.defaultAddr.needsQualityMode, isFalse);
      expect(DouyinSource.h264.needsQualityMode, isFalse);
      expect(DouyinSource.h265.needsQualityMode, isFalse);
      expect(DouyinSource.audioOnly.needsQualityMode, isFalse);
    });
  });

  group('DouyinConfig 序列化', () {
    test('默认值对齐参照实现（limit=4、webp、时长 0~300 秒）', () {
      final c = DouyinConfig();
      expect(c.source, DouyinSource.defaultAddr);
      expect(c.qualityMode, DouyinQualityMode.auto);
      expect(c.imageFormat, DouyinImageFormat.keep);
      expect(c.concurrency, 4);
      expect(c.timeStartSec, 0);
      expect(c.timeEndSec, 300);
      expect(c.timeRangeEnabled, isFalse);
      expect(c.includeLivePhoto, isTrue);
      expect(c.groupByAweme, isTrue);
      expect(c.includeBgm, isFalse);
      expect(c.skipDownloaded, isTrue,
          reason: '默认开启：配合下载历史，「下过的不再重下」');
      expect(c.filterLowQuality, isFalse);
      expect(c.filterByteVc1, isFalse);
      expect(c.customText, '');
      expect(c.isDefault, isTrue);
    });

    test('toJson → fromJson 往返不丢字段', () {
      final c = DouyinConfig(
        source: DouyinSource.qualityFirst,
        qualityMode: DouyinQualityMode.fps,
        imageFormat: DouyinImageFormat.jpgFirst,
        filterLowQuality: true,
        filterByteVc1: true,
        includeLivePhoto: false,
        includeBgm: true,
        skipDownloaded: true,
        groupByAweme: false,
        timeRangeEnabled: true,
        timeStartSec: 3,
        timeEndSec: 42,
        concurrency: 8,
        customText: '我的文本',
      );

      final back = DouyinConfig.fromJson(c.toJson());
      expect(back.source, c.source);
      expect(back.qualityMode, c.qualityMode);
      expect(back.imageFormat, c.imageFormat);
      expect(back.filterLowQuality, isTrue);
      expect(back.filterByteVc1, isTrue);
      expect(back.includeLivePhoto, isFalse);
      expect(back.includeBgm, isTrue);
      expect(back.skipDownloaded, isTrue);
      expect(back.groupByAweme, isFalse);
      expect(back.timeRangeEnabled, isTrue);
      expect(back.timeStartSec, 3);
      expect(back.timeEndSec, 42);
      expect(back.concurrency, 8);
      expect(back.customText, '我的文本');
    });

    test('空对象 / 部分缺字段时用默认值补齐（老配置升级路径）', () {
      final empty = DouyinConfig.fromJson(const {});
      expect(empty.isDefault, isTrue);

      final partial = DouyinConfig.fromJson(const {'concurrency': 10});
      expect(partial.concurrency, 10);
      expect(partial.source, DouyinSource.defaultAddr);
      expect(partial.imageFormat, DouyinImageFormat.keep);
    });

    test('任何一项偏离默认就不再 isDefault（折叠时的「已修改」圆点靠它）', () {
      expect(DouyinConfig().isDefault, isTrue);
      expect((DouyinConfig()..concurrency = 8).isDefault, isFalse);
      expect((DouyinConfig()..customText = 'x').isDefault, isFalse);
      expect((DouyinConfig()..includeBgm = true).isDefault, isFalse);
      expect((DouyinConfig()..timeRangeEnabled = true).isDefault, isFalse);
      expect((DouyinConfig()..source = DouyinSource.h264).isDefault, isFalse);
    });
  });

  group('Settings 里的抖音配置', () {
    test('encode → decode 往返保留抖音设置', () {
      final s = Settings();
      s.douyin
        ..source = DouyinSource.audioOnly
        ..concurrency = 6
        ..customText = '收藏';

      final back = Settings.decode(s.encode());
      expect(back.douyin.source, DouyinSource.audioOnly);
      expect(back.douyin.concurrency, 6);
      expect(back.douyin.customText, '收藏');
    });

    test('老配置（没有 douyin 键）读出来是默认值，不炸', () {
      final back = Settings.decode('{"state":{},"version":3}');
      expect(back.douyin.isDefault, isTrue);
    });

    test('坏 JSON 也被兜住', () {
      final back = Settings.decode('not json');
      expect(back.douyin.source, DouyinSource.defaultAddr);
    });
  });

  group('SettingsStore.setDouyin', () {
    test('改动生效并通知界面', () async {
      final store = SettingsStore();
      var notified = 0;
      store.addListener(() => notified++);

      await store.setDouyin((d) => d.concurrency = 12);

      expect(store.settings.douyin.concurrency, 12);
      expect(notified, 1);
    });

    test('没落盘句柄时 save 静默跳过（不抛异常）', () async {
      final store = SettingsStore();
      await store.setDouyin((d) => d.customText = 'x');
      expect(store.settings.douyin.customText, 'x');
    });
  });

  group('Aria2Coordinator.applyConcurrency 未启动时是 no-op', () {
    test('bootstrap 之前调用直接返回，不抛异常', () async {
      final c = Aria2Coordinator.instance;
      expect(c.booted, isFalse);
      await c.applyConcurrency(8);
      // 还是没有启动 —— 说明没有偷偷去拉 aria2 进程
      expect(c.booted, isFalse);
    });
  });
}
