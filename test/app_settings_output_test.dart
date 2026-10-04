import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:format_factory/models.dart';
import 'package:format_factory/state/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<ProviderContainer> makeContainer(
      [Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues(initial);
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    return c;
  }

  test('默认输出目标：三类均指向默认目录（Download/FormatExport）', () async {
    final c = await makeContainer();
    final s = c.read(appSettingsProvider);
    expect(s.outputTarget, AppSettings.targetDefault);
    for (final kind in MediaKind.values) {
      expect(s.targetOf(kind), AppSettings.targetDefault);
    }
  });

  test('设置输出目标后，所有类别统一生效并持久化到 out.target', () async {
    final c = await makeContainer();
    await c
        .read(appSettingsProvider.notifier)
        .setOutput(MediaKind.image, '/storage/emulated/0/Music');
    final s = c.read(appSettingsProvider);
    for (final kind in MediaKind.values) {
      expect(s.targetOf(kind), '/storage/emulated/0/Music');
    }
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('out.target'), '/storage/emulated/0/Music');
  });

  test('迁移：旧版三类设置完全一致时沿用该值', () async {
    final c = await makeContainer({
      'out.video': 'content://saf/tree/abc',
      'out.audio': 'content://saf/tree/abc',
      'out.image': 'content://saf/tree/abc',
    });
    expect(c.read(appSettingsProvider).outputTarget, 'content://saf/tree/abc');
  });

  test('迁移：旧版三类设置不一致时回落默认目录', () async {
    final c = await makeContainer({
      'out.video': 'content://saf/tree/abc',
      'out.audio': 'app',
      'out.image': 'content://saf/tree/abc',
    });
    expect(
        c.read(appSettingsProvider).outputTarget, AppSettings.targetDefault);
  });
}
