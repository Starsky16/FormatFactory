import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formatfactory/app.dart';
import 'package:formatfactory/state/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// B站缓存转视频页面：首页入口 + 空态渲染。
/// 真实缓存目录的读取与合并需要真机验证（Android/data 权限）。
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Widget wrap() => ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: const FormatFactoryApp(),
      );

  testWidgets('首页卡片可进入 B站缓存转视频页并显示引导文案', (tester) async {
    await tester.pumpWidget(wrap());

    // 首页是懒加载列表，B站卡片在底部 → 先滚动到可见再点击
    final entry = find.text('B站缓存转视频');
    await tester.scrollUntilVisible(
      entry,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(entry, findsOneWidget);

    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.text('把 B站缓存的视频合并成普通 MP4'), findsOneWidget);
    expect(find.text('选择缓存目录'), findsOneWidget);
  });
}
