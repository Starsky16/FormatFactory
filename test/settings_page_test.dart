import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formatfactory/models.dart';
import 'package:formatfactory/state/app_settings.dart';
import 'package:formatfactory/state/task_queue.dart';
import 'package:formatfactory/ui/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用固定任务列表替换真实队列，避免入队触发 FFmpeg / 原生通道。
class _FakeQueue extends TaskQueue {
  _FakeQueue(this.tasks);

  final List<ConvertTask> tasks;

  @override
  List<ConvertTask> build() => tasks;
}

ConvertTask _task(TaskStatus status) => ConvertTask(
      id: 't1',
      kind: MediaKind.audio,
      inputPath: '/tmp/a.flac',
      inputName: 'a.flac',
      presetId: 'audio_mp3',
      presetName: 'MP3',
      settings: ConvertSettings.empty,
      outputPath: '/tmp/a.mp3',
      createdAt: DateTime(2026, 1, 1),
      status: status,
    );

/// 设置页改造（清理工作区入口 + 版本号显示）的 widget 测试。
void main() {
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const packageInfoChannel =
      MethodChannel('dev.fluttercommunity.plus/package_info');

  late SharedPreferences prefs;
  late Directory supportDir;

  TestWidgetsFlutterBinding.ensureInitialized();

  /// 让 path_provider 的应用支持目录落在临时目录，供清理逻辑真删真建。
  void mockPathProvider(String supportPath) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') return supportPath;
      return null;
    });
  }

  /// 让 package_info_plus 读到构建产物版本号。
  void mockPackageInfo(String version, String buildNumber) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(packageInfoChannel, (call) async {
      if (call.method == 'getAll') {
        return <String, dynamic>{
          'appName': 'FormatFactory',
          'packageName': 'com.starksky16.formatfactory',
          'version': version,
          'buildNumber': buildNumber,
        };
      }
      return null;
    });
  }

  /// `testWidgets` 跑在 FakeAsync 区里，清理工作区走的是 dart:io 真实异步
  ///（`exists` / `list` / `delete` / `create`），不会自行完成；这里交替
  /// 「放真实事件循环跑一会 + 推进一帧」，直到 [finder] 命中或轮数用尽。
  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    int maxRounds = 80,
  }) async {
    for (var i = 0; i < maxRounds; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    supportDir = Directory.systemTemp.createTempSync('ff_settings');
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(packageInfoChannel, null);
    if (supportDir.existsSync()) supportDir.deleteSync(recursive: true);
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    List<ConvertTask> tasks = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          taskQueueProvider.overrideWith(() => _FakeQueue(tasks)),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('版本卡片显示构建产物版本号', (tester) async {
    mockPackageInfo('0.6.2', '20');
    await pumpSettings(tester);

    expect(find.text('版本'), findsOneWidget);
    expect(find.text('FormatFactory v0.6.2+20'), findsOneWidget);
  });

  testWidgets('队列空闲时清理工作区入口可用', (tester) async {
    await pumpSettings(tester);

    expect(find.text('清理工作区'), findsOneWidget);
    final tile = tester.widget<ListTile>(
      find.ancestor(of: find.text('清理工作区'), matching: find.byType(ListTile)),
    );
    expect(tile.enabled, isTrue);
    expect(tile.onTap, isNotNull);
    expect(find.textContaining('删除脱壳 / 转码 / B站导入留下的工作副本'), findsOneWidget);
  });

  testWidgets('队列有未结束任务时清理入口禁用并给出原因', (tester) async {
    await pumpSettings(tester, tasks: [_task(TaskStatus.running)]);

    final tile = tester.widget<ListTile>(
      find.ancestor(of: find.text('清理工作区'), matching: find.byType(ListTile)),
    );
    expect(tile.enabled, isFalse);
    expect(tile.onTap, isNull);
    expect(find.text('有任务正在排队或执行，结束后才能清理'), findsOneWidget);
  });

  testWidgets('点击清理先弹确认对话框，取消则不动工作区', (tester) async {
    mockPathProvider(supportDir.path);
    await pumpSettings(tester);

    await tester.tap(find.text('清理工作区'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('已导出到"下载/FormatExport"'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('确认清理后提示释放的空间，文件被清除', (tester) async {
    mockPathProvider(supportDir.path);
    // 造出一个有内容的工作区：<support>/FormatFactory_work/audio/xxx
    final workDir = Directory(
        '${supportDir.path}${Platform.pathSeparator}FormatFactory_work'
        '${Platform.pathSeparator}audio')
      ..createSync(recursive: true);
    File('${workDir.path}${Platform.pathSeparator}leftover.mp3')
        .writeAsStringSync('demo' * 512);

    await pumpSettings(tester);
    await tester.tap(find.text('清理工作区'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清理'));
    await pumpUntil(tester, find.textContaining('已清理工作区，释放'));

    expect(find.textContaining('已清理工作区，释放'), findsOneWidget);
    // 工作区骨架被重建（空目录存在），旧文件没了
    expect(
        Directory('${supportDir.path}${Platform.pathSeparator}FormatFactory_work')
            .existsSync(),
        isTrue);
    expect(File('${workDir.path}${Platform.pathSeparator}leftover.mp3').existsSync(),
        isFalse);

    // 收尾：让 SnackBar 自动消失，别把计时器留到测试结束
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('工作区本来就是空的时候给出对应提示', (tester) async {
    mockPathProvider(supportDir.path);
    await pumpSettings(tester);
    await tester.tap(find.text('清理工作区'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清理'));
    await pumpUntil(tester, find.text('工作区已经是空的'));

    expect(find.text('工作区已经是空的'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
