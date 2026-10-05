import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/app_prefs.dart';
import 'package:parse_dl/models/creation_task.dart';
import 'package:parse_dl/models/download_filter.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/models/user.dart';
import 'package:parse_dl/services/app_state.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/creation_task_store.dart';

/// 回归守护：「主页点开始下载 → 立刻出现在下载管理」。
///
/// 旧实现的症状是：点「开始下载」后**同步**把该用户剩余页全部拉完（`loadAllMedias`），
/// 界面卡在那里，拉完就停 —— 用户以为没反应，得再点一次才把任务推进下载管理。
///
/// 原版的做法（`createCreationTask` + `scheduleCreationTasks`）是：
/// 点一下只**登记**一个任务就返回，翻页与入队交给后台串行队列。
/// 所以这里断言的核心就是 **`create()` 是同步的**：
/// 它 return 的那一刻，任务已经在 `CreationTaskStore.tasks` 里了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CreationTaskStore store;

  setUp(() async {
    AppPrefs.setMockInitialValues({});
    final appState = await AppState.restore();
    store = CreationTaskStore(
      appState: appState,
      coordinator: Aria2Coordinator.instance,
    );
  });

  tearDown(() => store.dispose());

  const user = TwitterUser(
    id: '44196397',
    name: '测试用户',
    screenName: 'testuser',
  );

  test('create() 同步返回，任务立刻可见（不等待翻页）', () {
    expect(store.count, 0);

    final t = store.create(user, const DownloadFilter());

    // 关键断言：create 返回时队列里就已经有它了 ——
    // 下载管理页第一次 build 就能渲染出「共 1 个任务创建中」
    expect(store.count, 1);
    expect(store.tasks.single.id, t.id);
    expect(store.tasks.single.user.screenName, 'testuser');
    expect(t.completeCount, 0);
    expect(t.skipCount, 0);
  });

  test('连点多次 → 每个任务都独立登记在队列里', () {
    final a = store.create(user, const DownloadFilter());
    final b = store.create(user, const DownloadFilter());

    expect(store.count, 2);
    expect(a.id, isNot(b.id));
  });

  test('过滤条件是创建时的快照 —— 之后改界面不影响已登记的任务', () {
    final filter = DownloadFilter(
      dateFrom: DateTime(2024, 1, 1),
      mediaTypes: const {MediaType.video},
    );
    final t = store.create(user, filter);

    expect(t.filter.dateFrom, DateTime(2024, 1, 1));
    expect(t.filter.mediaTypes, {MediaType.video});
    // 同一个对象，而不是「每次读都去 store 里取最新值」
    expect(identical(t.filter, filter), isTrue);
  });

  test('aria2 未就绪时任务失败出队，而不是永远挂在「创建中」', () async {
    expect(Aria2Coordinator.instance.booted, isFalse);

    store.create(user, const DownloadFilter());
    expect(store.count, 1); // 同步可见

    // 让后台泵跑完（create 里是 unawaited(_pump())）
    await pumpEventQueue();

    expect(store.count, 0);
    expect(store.active, isNull);
  });

  test('displayName：有昵称用昵称，只有 @用户名 时补 @', () {
    final named = CreationTask(
      id: 'x',
      user: user,
      filter: const DownloadFilter(),
    );
    expect(named.displayName, '测试用户');

    final onlySn = CreationTask(
      id: 'y',
      user: const TwitterUser(id: '1', screenName: 'foo'),
      filter: const DownloadFilter(),
    );
    expect(onlySn.displayName, '@foo');

    final empty = CreationTask(
      id: 'z',
      user: const TwitterUser(id: '1'),
      filter: const DownloadFilter(),
    );
    expect(empty.displayName, '未知用户');
  });
}
