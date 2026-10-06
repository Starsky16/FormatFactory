import 'package:flutter_test/flutter_test.dart';
import 'package:formatfactory/formats.dart';
import 'package:formatfactory/formats_data.dart';
import 'package:formatfactory/models.dart';
import 'package:formatfactory/services/bili_cache.dart';
import 'package:formatfactory/services/ffmpeg_engine.dart';
import 'package:formatfactory/ui/convert_flow.dart';

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
    String outputPath = '/tmp/out.bin',
    bool inputHasAttachedPic = false,
  }) {
    final preset = presetById(kind, presetId)!;
    final task = taskFor(kind, presetId, settingsOf(preset, overrides: overrides),
        inputPath: inputPath);
    return FfmpegEngine.buildCommand(ConvertTask(
      id: task.id,
      kind: task.kind,
      inputPath: task.inputPath,
      inputName: task.inputName,
      presetId: task.presetId,
      presetName: task.presetName,
      settings: task.settings,
      outputPath: outputPath,
      createdAt: task.createdAt,
      inputHasAttachedPic: inputHasAttachedPic,
    ));
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

  group('§12 标签显式保留', () {
    test('命令显式带 -map_metadata 0（视频任务）', () {
      expect(commandFor(MediaKind.video, 'mp4_h264'), contains('-map_metadata 0'));
    });

    test('音频任务也带 -map_metadata 0', () {
      expect(commandFor(MediaKind.audio, 'audio_mp3'), contains('-map_metadata 0'));
    });

    test('B 站合并任务同样显式取输入 0 的标签', () {
      final cmd = FfmpegEngine.buildCommand(ConvertTask(
        id: 't2',
        kind: MediaKind.video,
        inputPath: '/tmp/video.m4s',
        inputName: 'video.m4s',
        presetId: BiliCache.kCopyPresetId,
        presetName: 'B站合并',
        settings: ConvertSettings.empty,
        outputPath: '/tmp/out.mp4',
        mergeAudioPath: '/tmp/audio.m4s',
        createdAt: DateTime(2026, 1, 1),
      ));
      expect(cmd, contains('-map_metadata 0'));
      expect(cmd, contains('-c copy'));
    });
  });

  group('§12 封面保留（音频输出映射 attached_pic）', () {
    test('带封面的音频转 M4A：去掉 -vn 并映射封面流', () {
      final cmd = commandFor(MediaKind.audio, 'audio_m4a',
          inputPath: '/tmp/in.mp3',
          outputPath: '/tmp/out.m4a',
          inputHasAttachedPic: true);
      expect(cmd, isNot(contains('-vn')), reason: '-vn 会把封面一起丢掉');
      expect(cmd, contains('-map 0:a:0'));
      expect(cmd, contains('-map 0:v:0'));
      expect(cmd, contains('-c:v copy'));
      expect(cmd, contains('-disposition:v:0 attached_pic'));
    });

    test('带封面的音频转 MP3 / FLAC 同样映射', () {
      for (final entry in {
        'audio_mp3': '/tmp/out.mp3',
        'audio_flac': '/tmp/out.flac',
      }.entries) {
        final cmd = commandFor(MediaKind.audio, entry.key,
            inputPath: '/tmp/in.mp3',
            outputPath: entry.value,
            inputHasAttachedPic: true);
        expect(cmd, isNot(contains('-vn')), reason: entry.key);
        expect(cmd, contains('attached_pic'), reason: entry.key);
      }
    });

    test('WAV 容器放不下封面：保持 -vn，不映射', () {
      final cmd = commandFor(MediaKind.audio, 'audio_wav',
          inputPath: '/tmp/in.mp3',
          outputPath: '/tmp/out.wav',
          inputHasAttachedPic: true);
      expect(cmd, contains('-vn'));
      expect(cmd, isNot(contains('attached_pic')));
    });

    test('ogg/opus 输出暂不映射封面（防回归白名单外）', () {
      for (final entry in {
        'audio_ogg': '/tmp/out.ogg',
        'audio_opus': '/tmp/out.opus',
      }.entries) {
        final cmd = commandFor(MediaKind.audio, entry.key,
            inputPath: '/tmp/in.mp3',
            outputPath: entry.value,
            inputHasAttachedPic: true);
        expect(cmd, contains('-vn'), reason: entry.key);
        expect(cmd, isNot(contains('attached_pic')), reason: entry.key);
      }
    });

    test('无封面的音频保持原行为（-vn 在）', () {
      final cmd = commandFor(MediaKind.audio, 'audio_m4a',
          inputPath: '/tmp/in.mp3', outputPath: '/tmp/out.m4a');
      expect(cmd, contains('-vn'));
      expect(cmd, isNot(contains('attached_pic')));
    });

    test('视频任务不受封面映射影响', () {
      final cmd = commandFor(MediaKind.video, 'mp4_h264',
          inputPath: '/tmp/in.mp3',
          outputPath: '/tmp/out.mp4',
          inputHasAttachedPic: true);
      expect(cmd, isNot(contains('attached_pic')));
    });
  });

  group('§12 JPG 直通保 EXIF（未改尺寸/质量时流复制）', () {
    test('jpg→jpg 原始尺寸 + 默认画质：-c:v copy，不重编码', () {
      final cmd = commandFor(MediaKind.image, 'img_jpg',
          inputPath: '/tmp/in.jpg', outputPath: '/tmp/out.jpg');
      expect(cmd, contains('-c:v copy'));
      expect(cmd, isNot(contains('mjpeg')));
    });

    test('改了画质则照常重编码', () {
      final cmd = commandFor(MediaKind.image, 'img_jpg',
          inputPath: '/tmp/in.jpg',
          outputPath: '/tmp/out.jpg',
          overrides: {SettingKey.imageQuality: '60'});
      expect(cmd, contains('mjpeg'));
      expect(cmd, isNot(contains('-c:v copy')));
    });

    test('改了尺寸则照常重编码', () {
      final cmd = commandFor(MediaKind.image, 'img_jpg',
          inputPath: '/tmp/in.jpg',
          outputPath: '/tmp/out.jpg',
          overrides: {SettingKey.resolution: '1280 宽'});
      expect(cmd, contains('mjpeg'));
    });

    test('jpg→png 不直通', () {
      final cmd = commandFor(MediaKind.image, 'img_png',
          inputPath: '/tmp/in.jpg', outputPath: '/tmp/out.png');
      expect(cmd, contains('-c:v png'));
    });

    test('jpg→jpg 但质量被设为非默认值时不直通', () {
      final cmd = commandFor(MediaKind.image, 'img_custom',
          inputPath: '/tmp/in.jpg',
          outputPath: '/tmp/out.jpg',
          overrides: {SettingKey.container: 'JPG', SettingKey.imageQuality: '90'});
      expect(cmd, contains('mjpeg'));
    });
  });
}