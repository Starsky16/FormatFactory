import 'package:flutter_test/flutter_test.dart';
import 'package:format_factory/models.dart';
import 'package:format_factory/state/task_queue.dart';

/// 分段入队展开逻辑测试：填了 segmentMinutes 的任务在入队时
/// 展开成 N 个带各自 trimStart/trimEnd 的任务；压缩任务每段均分目标体积。
void main() {
  ConvertTask base({
    String presetId = 'mp4_h264',
    Map<SettingKey, String> values = const {},
    double? duration = 1920,
    String output = '/out/a.mp4',
  }) =>
      ConvertTask(
        id: 't1',
        kind: MediaKind.video,
        inputPath: '/in/a.avi',
        inputName: 'a.avi',
        presetId: presetId,
        presetName: presetId,
        settings: ConvertSettings(values),
        outputPath: output,
        createdAt: DateTime(2026, 1, 1),
        inputDurationSeconds: duration,
      );

  group('expandSegments', () {
    test('没填分段时原样返回（同一个任务）', () {
      final t = base();
      expect(expandSegments(t), [same(t)]);
    });

    test('非法段秒（0/负数）或无源时长：原样返回', () {
      final t0 = base(values: {SettingKey.segmentMinutes: '0'});
      expect(expandSegments(t0), [same(t0)]);
      final tNeg = base(values: {SettingKey.segmentMinutes: '-3'});
      expect(expandSegments(tNeg), [same(tNeg)]);
      final tNoDur = base(duration: null, values: {SettingKey.segmentMinutes: '10'});
      expect(expandSegments(tNoDur), [same(tNoDur)]);
    });

    test('32 分钟每段 10 分钟 → 4 个任务，_part1.._part4，边界正确', () {
      final parts = expandSegments(base(
        values: {SettingKey.segmentMinutes: '10'},
      ));
      expect(parts, hasLength(4));
      expect(parts[0].outputPath, '/out/a_part1.mp4');
      expect(parts[1].outputPath, '/out/a_part2.mp4');
      expect(parts[3].outputPath, '/out/a_part3.mp4'.replaceFirst('part3', 'part4'));
      // 边界：段 i = [i*600, (i+1)*600]，末段到 1920
      expect(parts[0].settings.of(SettingKey.trimStart), '0:00');
      expect(parts[0].settings.of(SettingKey.trimEnd), '10:00');
      expect(parts[1].settings.of(SettingKey.trimStart), '10:00');
      expect(parts[1].settings.of(SettingKey.trimEnd), '20:00');
      expect(parts[3].settings.of(SettingKey.trimStart), '30:00');
      expect(parts[3].settings.of(SettingKey.trimEnd), '32:00');
      // 任务元信息保留
      expect(parts[1].presetId, 'mp4_h264');
      expect(parts[1].inputName, 'a.avi');
    });

    test('分段 + 裁剪叠加：先裁再分，段边界落在裁剪区间内', () {
      final parts = expandSegments(base(values: {
        SettingKey.segmentMinutes: '10',
        SettingKey.trimStart: '5:00',
        SettingKey.trimEnd: '25:00',
      }));
      expect(parts, hasLength(2));
      expect(parts[0].settings.of(SettingKey.trimStart), '5:00');
      expect(parts[0].settings.of(SettingKey.trimEnd), '15:00');
      expect(parts[1].settings.of(SettingKey.trimStart), '15:00');
      expect(parts[1].settings.of(SettingKey.trimEnd), '25:00');
    });

    test('压缩任务分段：每段均分目标体积（余数给前几段）', () {
      final parts = expandSegments(base(
        presetId: 'video_compress',
        duration: 1920,
        values: {
          SettingKey.segmentMinutes: '10',
          SettingKey.targetVolumeMB: '50',
        },
      ));
      expect(parts, hasLength(4));
      // 50 = 12*4 + 2 → 前 2 段 13MB，后 2 段 12MB
      expect(parts[0].settings.of(SettingKey.targetVolumeMB), '13');
      expect(parts[1].settings.of(SettingKey.targetVolumeMB), '13');
      expect(parts[2].settings.of(SettingKey.targetVolumeMB), '12');
      expect(parts[3].settings.of(SettingKey.targetVolumeMB), '12');
    });

    test('非压缩任务分段：不引入 targetVolumeMB', () {
      final parts = expandSegments(base(values: {SettingKey.segmentMinutes: '16'}));
      expect(parts, hasLength(2));
      expect(parts[0].settings.of(SettingKey.targetVolumeMB), isEmpty);
    });

    test('段数只有 1 时不加 _part 后缀（等于整体）', () {
      final t = base(duration: 300, values: {SettingKey.segmentMinutes: '10'});
      final parts = expandSegments(t);
      expect(parts, hasLength(1));
      expect(parts.single.outputPath, '/out/a.mp4');
    });
  });

  group('ConvertTask.inputBytes', () {
    test('可以携带源体积并参与 copyWith', () {
      final t = base().copyWith(inputBytes: 123456);
      expect(t.inputBytes, 123456);
      // 未设置时为 null
      expect(base().inputBytes, isNull);
    });
  });

  group('summary 不受新参数破坏', () {
    test('含裁剪/分段设置的 summary 正常拼接', () {
      final s = ConvertSettings({
        SettingKey.trimStart: '0',
        SettingKey.segmentMinutes: '10',
      });
      expect(s.summary, contains('10'));
    });
  });
}
