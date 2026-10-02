import 'package:flutter_test/flutter_test.dart';
import 'package:format_factory/formats.dart';
import 'package:format_factory/formats_data.dart';
import 'package:format_factory/models.dart';
import 'package:format_factory/services/ffmpeg_engine.dart';
import 'package:format_factory/ui/convert_flow.dart';

/// 转码补强的命令拼装测试（T8 视频→音频 / T9 仅换容器 / T10 自定义 MP4 faststart）。
/// 只断言"拼出来的命令"，不跑真实 FFmpeg。
void main() {
  ConvertTask taskFor(
    MediaKind kind,
    String presetId,
    ConvertSettings settings, {
    String inputPath = '/tmp/in.mp4',
  }) {
    return ConvertTask(
      id: 't1',
      kind: kind,
      inputPath: inputPath,
      inputName: 'in.mp4',
      presetId: presetId,
      presetName: presetId,
      settings: settings,
      outputPath: '/tmp/out.bin',
      createdAt: DateTime(2026, 1, 1),
    );
  }

  /// 取某个预设的"界面初始值"，再按需覆盖个别参数。
  ConvertSettings settingsOf(
    FormatPreset preset, {
    Map<SettingKey, String> overrides = const {},
  }) {
    return ConvertSettings({
      for (final f in preset.fields) f.key: f.initialValue,
      ...overrides,
    });
  }

  String commandFor(
    MediaKind kind,
    String presetId, {
    Map<SettingKey, String> overrides = const {},
    String inputPath = '/tmp/in.mp4',
  }) {
    final preset = presetById(kind, presetId)!;
    return FfmpegEngine.buildCommand(
      taskFor(kind, presetId, settingsOf(preset, overrides: overrides),
          inputPath: inputPath),
    );
  }

  group('T8 视频 → 音频（只提取音轨）', () {
    test('音频转换允许把视频当输入', () {
      expect(kAudioInputExtensions, containsAll(kAudioExtensions));
      expect(kAudioInputExtensions, containsAll(['mp4', 'mkv', 'mov', 'webm']));
    });

    test(r'每个音频预设都带 -vn（视频输入不会把画面写进输出）', () {
      for (final preset in presetsFor(MediaKind.audio)) {
        final cmd = commandFor(MediaKind.audio, preset.id);
        expect(cmd, contains('-vn'), reason: '${preset.id} 缺少 -vn');
      }
    });

    test('纯音频输入也带 -vn（无视频流时是空操作）', () {
      final cmd = commandFor(MediaKind.audio, 'audio_mp3',
          inputPath: '/tmp/in.flac');
      expect(cmd, contains('-vn'));
      expect(cmd, contains('-i "/tmp/in.flac"'));
    });
  });

  group('T9 仅换容器（remux，不重新编码）', () {
    test('预设存在且排在"自定义"之前', () {
      final ids = presetsFor(MediaKind.video).map((p) => p.id).toList();
      expect(ids, contains('video_remux'));
      expect(ids.indexOf('video_remux'), lessThan(ids.indexOf('video_custom')));
    });

    test('输出 MP4：-c copy + faststart，且显式 -map 保住多音轨', () {
      final cmd = commandFor(MediaKind.video, 'video_remux',
          overrides: {SettingKey.container: 'MP4'});
      expect(cmd, contains('-c copy'));
      expect(cmd, contains('-map 0:v?'));
      expect(cmd, contains('-map 0:a?'));
      expect(cmd, contains('+faststart'));
      expect(cmd, isNot(contains('libx264')));
    });

    test('输出 MKV：-c copy 但不加 movflags', () {
      final cmd = commandFor(MediaKind.video, 'video_remux',
          overrides: {SettingKey.container: 'MKV'});
      expect(cmd, contains('-c copy'));
      expect(cmd, isNot(contains('faststart')));
      expect(cmd, endsWith('"/tmp/out.bin"'));
    });

    test('扩展名跟随所选容器', () {
      final preset = presetById(MediaKind.video, 'video_remux')!;
      expect(
        preset.outExt(settingsOf(preset, overrides: {SettingKey.container: 'MKV'})),
        'mkv',
      );
      expect(
        preset.outExt(settingsOf(preset, overrides: {SettingKey.container: 'WebM'})),
        'webm',
      );
    });
  });

  group('T10 自定义视频：MP4/MOV 补 +faststart', () {
    test('自定义 MP4 含 +faststart（与内置 MP4 预设一致）', () {
      final cmd = commandFor(MediaKind.video, 'video_custom');
      expect(cmd, contains('+faststart'));
    });

    test('自定义 MOV 也含 +faststart', () {
      final cmd = commandFor(MediaKind.video, 'video_custom',
          overrides: {SettingKey.container: 'MOV'});
      expect(cmd, contains('+faststart'));
    });

    test('非 MP4/MOV 容器不加 +faststart', () {
      for (final container in ['MKV', 'WebM', 'AVI', 'FLV', '3GP']) {
        final cmd = commandFor(MediaKind.video, 'video_custom',
            overrides: {SettingKey.container: container});
        expect(cmd, isNot(contains('faststart')),
            reason: '$container 不该出现 faststart');
      }
    });

    test('内置 MP4 预设的 faststart 行为未回归', () {
      expect(commandFor(MediaKind.video, 'mp4_h264'), contains('+faststart'));
      expect(commandFor(MediaKind.video, 'mkv_hevc'), isNot(contains('faststart')));
    });
  });

  group('isMovContainer', () {
    test('只认 MP4 / MOV', () {
      const mov = ConvertSettings({SettingKey.container: 'MOV'});
      const mp4 = ConvertSettings({SettingKey.container: 'MP4'});
      const mkv = ConvertSettings({SettingKey.container: 'MKV'});
      expect(isMovContainer(mov), isTrue);
      expect(isMovContainer(mp4), isTrue);
      expect(isMovContainer(mkv), isFalse);
    });
  });
}