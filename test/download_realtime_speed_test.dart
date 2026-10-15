import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/pages/download_management_page.dart';
import 'package:parse_dl/services/aria2.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/theme/app_theme.dart';

/// 「下载管理页显示实时速度」的判据（2026-10-15 用户真机反馈：
/// 「在下载管理里面加实时下载速度」）。
///
/// 数据链路是四层：`aria2.tellStatus.downloadSpeed` → `AriaTask.speedBytesPerSec`
/// → `Aria2Coordinator._pollActive` 调 `DownloadStore.updateSpeed` →
/// `DownloadTask.speedReadable` → `DownloadSpeedRow`。
/// **不在前端用两次进度采样估算** —— 切源重投、暂停恢复、连接刚建立时，
/// 估算值给出的数字没有意义。
///
/// ## 为什么页面那一层只渲染 `DownloadSpeedRow`
///
/// 整页 `pumpWidget(DownloadManagementPage)` 会牵进两个在假时钟下永不落地的
/// 东西：`Aria2Coordinator.instance` 的 `Timer.periodic`（每秒轮询），以及
/// `AppState.restore()` 的真实文件 I/O。实测直接挂死 10 分钟
/// （项目笔记里的「FakeAsync 永久挂死」）。所以速度的渲染判据单独渲染那一个
/// 部件；**「终态行不留旧速度」的责任在 store 层**，由下面 store 那一组的
/// 判据覆盖（那里每条都带负控制）。
void main() {
  group('AriaTask：解析 aria2 的 downloadSpeed', () {
    // 真机 RPC 取样（2026-10-15）："downloadSpeed":"384410"，
    // 与 max-download-limit=400K 对得上。
    test('响应带 downloadSpeed → 解析成字节/秒', () {
      final t = AriaTask.fromJson(const {
        'gid': 'g1',
        'status': 'active',
        'completedLength': '1024',
        'totalLength': '4096',
        'downloadSpeed': '384410',
        'files': [
          {'path': r'C:\tmp\a.mp4'},
        ],
      });
      expect(t.speedBytesPerSec, 384410, reason: '字符串要转成 int，否则下游无法比较');
    });

    test('字段缺失 → null（不是 0）', () {
      final t = AriaTask.fromJson(const {
        'gid': 'g1',
        'status': 'active',
        'completedLength': '1024',
        'totalLength': '4096',
        'files': [
          {'path': r'C:\tmp\a.mp4'},
        ],
      });
      // 必须与「aria2 说现在就是 0」区分开：那个是 0，这个是「没有数据」。
      expect(t.speedBytesPerSec, isNull);
    });

    test('aria2 暂停后回 "0" → 解析成 0（不是 null）', () {
      final t = AriaTask.fromJson(const {
        'gid': 'g1',
        'status': 'paused',
        'completedLength': '1024',
        'totalLength': '4096',
        'downloadSpeed': '0',
        'files': [
          {'path': r'C:\tmp\a.mp4'},
        ],
      });
      expect(t.speedBytesPerSec, 0);
    });
  });

  group('DownloadTask：人类可读的速度', () {
    DownloadTask taskWith(int? bytes) => DownloadTask(
          localId: 'l1',
          media: _media(),
          saveDir: r'C:\tmp',
        )..speedBytesPerSec = bytes;

    test('不同量级给不同单位', () {
      // 舍入沿用 `_humanBytes`：≥10 取整，<10 留一位小数。
      expect(taskWith(512).speedReadable, '512 B/s');
      expect(taskWith(2048).speedReadable, '2.0 KB/s');
      expect(taskWith(1024 * 1024 * 3 ~/ 2).speedReadable, '1.5 MB/s');
      expect(taskWith(384410).speedReadable, '375 KB/s');
    });

    test('null / 0 / 负值 → 空串（界面据此不画）', () {
      // null = 这个源压根不给速度；0 = aria2 说此刻没有速率。
      // 两者都不该画 —— 暂停 / 已完成 / 失败的行上画个「0 B/s」，
      // 等于告诉用户「它正在以零速下载」。
      expect(taskWith(null).speedReadable, '');
      expect(taskWith(0).speedReadable, '');
      expect(taskWith(-1).speedReadable, '', reason: '负值同样是「没有速度」');
    });
  });

  group('DownloadStore：写速度与离开下载态即清空', () {
    late DownloadStore store;
    late String localId;

    setUp(() {
      store = DownloadStore();
      localId = store.addPending(_media(), r'C:\tmp');
      store.markActive(localId, 'gid-1');
    });

    test('updateSpeed 把速度写进行内（正是 _pollActive 调的那个入口）', () {
      store.updateSpeed('gid-1', 384410);
      final t = store.tasks.firstWhere((e) => e.localId == localId);
      expect(t.speedBytesPerSec, 384410);
      expect(t.speedReadable, '375 KB/s'); // ≥10 取整，见 _humanBytes
    });

    test('同一值重复写不通知（下载中每秒一轮，不能每轮都重建界面）', () {
      var notified = 0;
      store.addListener(() => notified++);
      store.updateSpeed('gid-1', 1000);
      expect(notified, 1);
      store.updateSpeed('gid-1', 1000);
      expect(notified, 1, reason: '值没变就不要再 notify');
      store.updateSpeed('gid-1', 2000);
      expect(notified, 2);
    });

    test('未知 gid 安全返回（轮询与任务表有短暂错位）', () {
      store.updateSpeed('nope', 1000); // 不该抛
      expect(_speedOf(store, localId), isNull);
    });

    test('完成 / 失败 / 暂停 → 速度清空（不留过期假数据）', () {
      store.updateSpeed('gid-1', 2048);
      expect(_speedOf(store, localId), 2048);

      store.markComplete('gid-1');
      expect(_speedOf(store, localId), isNull,
          reason: '「已完成 5 分钟」的行上挂着旧速度就是假数据');

      store.markResumed(localId);
      store.markActive(localId, 'gid-1');
      store.updateSpeed('gid-1', 4096);
      expect(_speedOf(store, localId), 4096);
      store.markErrorByGid('gid-1', 'boom');
      expect(_speedOf(store, localId), isNull, reason: '失败行同理');

      store.markResumed(localId);
      store.markActive(localId, 'gid-1');
      store.updateSpeed('gid-1', 8192);
      expect(_speedOf(store, localId), 8192);
      store.markPaused(localId);
      expect(_speedOf(store, localId), isNull,
          reason: '暂停不是「零速下载」，是不显示');
    });

    test('markActive / markNote / renameTaskFile 整体重建时不能丢速度', () {
      // 这三处都是「构造新 DownloadTask 替换旧对象」的写法。漏掉
      // speedBytesPerSec 会让「恢复下载 / 改备注 / 改文件名」之后速度显示
      // 静默消失（2026-10-15 实测到的 bug，三条路径都会中）。
      store.updateSpeed('gid-1', 4096);
      expect(_speedOf(store, localId), 4096);

      store.markActive(localId, 'gid-1');
      expect(_speedOf(store, localId), 4096, reason: 'markActive 重建后丢了速度');

      store.markNote(localId, '部分成功');
      expect(_speedOf(store, localId), 4096, reason: 'markNote 重建后丢了速度');

      expect(store.renameTaskFile(localId, 'new-name.mp4'), isTrue);
      expect(_speedOf(store, localId), 4096, reason: '改名后丢了速度');
    });

    test('清速度会通知旁观者（否则界面收不到新值）', () {
      var notified = 0;
      store.addListener(() => notified++);
      store.updateSpeed('gid-1', 1024);
      store.markComplete('gid-1');
      expect(notified, greaterThanOrEqualTo(1));
    });
  });

  group('任务表序列化：速度不落盘', () {
    test('restoreFromJson 之后速度为 null（重启不残留上次会话的速度）', () {
      // 用 store 自己的 encode() 走一遍「写出去再读回来」，比手工拼 JSON
      // 更接近真实重启路径。
      final store = DownloadStore();
      final id = store.addPending(_media(), r'C:\tmp');
      store.markActive(id, 'gid-1');
      store.updateSpeed('gid-1', 2 * 1024 * 1024);
      expect(_speedOf(store, id), 2 * 1024 * 1024);

      final raw = store.encode();
      expect(raw.contains('speedBytesPerSec'), isFalse,
          reason: '一帧快照固化进磁盘 = 重启后读到上次会话的旧速度');

      final back = DownloadStore();
      back.restoreFromJson(raw);
      expect(_speedOf(back, id), isNull);
      // 那一行的状态得读回来（证明真的读进去了，不是空表）。
      expect(back.tasks, hasLength(1));
      expect(back.tasks.single.status, DownloadStatus.active);
    });
  });

  group('速度那一行：只有真有速度时才画', () {
    Future<void> pumpRow(WidgetTester tester, int? speed) async {
      final t = DownloadTask(
        localId: 'l1',
        media: _media(),
        saveDir: r'C:\tmp',
        status: DownloadStatus.active,
      )..speedBytesPerSec = speed;

      await tester.pumpWidget(
        AppTheme(
          colors: AppColors.dark,
          brightness: Brightness.dark,
          child: MaterialApp(
            home: Scaffold(body: DownloadSpeedRow(task: t)),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('有速度 → 画出数字与图标', (tester) async {
      await pumpRow(tester, 2 * 1024 * 1024);
      expect(find.text('2.0 MB/s'), findsOneWidget);
      expect(find.byIcon(Icons.speed_rounded), findsOneWidget);
    });

    testWidgets('null → 整条不画（图标也不留）', (tester) async {
      await pumpRow(tester, null);
      expect(find.textContaining('B/s'), findsNothing);
      expect(find.byIcon(Icons.speed_rounded), findsNothing);
    });

    testWidgets('0 → 也不画（不能画成「0 B/s」宣称它正以零速下载）', (tester) async {
      await pumpRow(tester, 0);
      expect(find.textContaining('B/s'), findsNothing);
      expect(find.byIcon(Icons.speed_rounded), findsNothing);
    });
  });
}

/// 找某一行当前的速度（null = 没有）。
int? _speedOf(DownloadStore store, String localId) =>
    store.tasks.firstWhere((e) => e.localId == localId).speedBytesPerSec;

Media _media({String id = 'm1'}) => Media(
      id: id,
      type: MediaType.image,
      url: 'https://cdn.example.com/$id.jpg',
      source: 'x',
    );