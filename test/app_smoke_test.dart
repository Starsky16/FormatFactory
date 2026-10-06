import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formatfactory/app.dart';
import 'package:formatfactory/state/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 冒烟测试：应用能正常启动并渲染首页。
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

  testWidgets('启动并显示首页标题', (WidgetTester tester) async {
    await tester.pumpWidget(wrap());
    // 首页 AppBar 标题"格式工厂"应出现
    expect(find.text('格式工厂'), findsWidgets);
    // 三个媒体入口都在
    expect(find.text('视频转换'), findsOneWidget);
    expect(find.text('音频转换'), findsOneWidget);
    expect(find.text('图片转换'), findsOneWidget);
  });
}
