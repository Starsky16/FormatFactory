import 'package:flutter_test/flutter_test.dart';
import 'package:format_factory/models.dart';
import 'package:format_factory/services/ffmpeg_engine.dart';

/// FFmpeg 引擎的裁剪注入与压缩命令拼装测试。
/// 重点：-ss 必须位于 -i 之前（输入级 seek）、remux+裁剪组合、
/// 两遍编码命令的码率/maxrate/bufsize 与音频降档。
void main() {
  ConvertTask task({
    String presetId = 'mp4_h264',
    Map<SettingKey, String> values = const {},
    double? duration = 1920,
  }) =>
      ConvertTask(
        id: 't1',
        kind: MediaKind.video,
        inputPath: '/in/a.avi',
        inputName: 'a.avi',
        presetId: presetId,
        presetName: presetId,
        settings: ConvertSettings(values),
        outputPath: '/out/a.mp4',
        createdAt: DateTime(2026, 1, 1),
        inputDurationSeconds: duration,
      );

  // ---------- 裁剪注入（普通预设） ----------

  group('裁剪注入', () {
    test('-ss 位于 -i 之前，-t 为有效时长', () {
      final cmd = FfmpegEngine.buildCommand(task(
        values: {SettingKey.trimStart: '10', SettingKey.trimEnd: '70'},
      ));
      expect(cmd, contains('-ss 10'));
      expect(cmd.indexOf('-ss 10'), lessThan(cmd.indexOf('-i ')));
      expect(cmd, contains('-t 60'));
    });

    test('remux（仅换容器）+ 裁剪：-c copy 保留，关键帧粗切', () {
      final cmd = FfmpegEngine.buildCommand(task(
        presetId: 'video_remux',
        values: {SettingKey.trimStart: '1:00', SettingKey.trimEnd: '2:00'},
      ));
      expect(cmd, contains('-c copy'));
      expect(cmd, contains('-ss 60'));
      expect(cmd.indexOf('-ss 60'), lessThan(cmd.indexOf('-i ')));
      expect(cmd, contains('-t 60'));
    });

    test('只填开始时间：从该点切到结尾，-t 为剩余时长', () {
      final cmd = FfmpegEngine.buildCommand(task(
        values: {SettingKey.trimStart: '5:00'},
      ));
      expect(cmd, contains('-ss 300'));
      expect(cmd, contains('-t 1620'));
    });

    test('无源时长时只填结束时间：把结束时刻当作时长', () {
      final cmd = FfmpegEngine.buildCommand(task(
        duration: null,
        values: {SettingKey.trimEnd: '30'},
      ));
      expect(cmd, contains('-t 30'));
    });

    test('裁剪越界/倒序视为无效：不注入任何参数', () {
      final cmd = FfmpegEngine.buildCommand(task(
        values: {SettingKey.trimStart: '99:00', SettingKey.trimEnd: '100:00'},
      ));
      expect(cmd, isNot(contains('-ss ')));
      expect(cmd, isNot(contains('-t ')));
    });

    test('结束时间夹取到源时长', () {
      final cmd = FfmpegEngine.buildCommand(task(
        values: {SettingKey.trimEnd: '99:00'},
      ));
      // 99:00 超过源 32 分钟 → 覆盖全程，不加参数
      expect(cmd, isNot(contains('-t ')));
      expect(cmd, isNot(contains('-ss ')));
    });
  });

  // ---------- 压缩命令（两遍编码） ----------

  group('压缩命令 buildCompressCommand', () {
    // 50 MiB / 300s → 0.98*1398.1-128 ≈ 1242 kbps
    Map<SettingKey, String> compressValues({
      String targetMB = '50',
      String? resolutionCap,
      String? fpsCap,
    }) =>
        {
          SettingKey.targetVolumeMB: targetMB,
          SettingKey.resolutionCap: ?resolutionCap,
          SettingKey.fpsCap: ?fpsCap,
        };

    test('pass1：分析遍，-an -f null，带相同码率与 passlogfile', () {
      final cmd = FfmpegEngine.buildCompressCommand(
        task(
          presetId: FfmpegEngine.compressPresetId,
          duration: 300,
          values: compressValues(),
        ),
        pass: 1,
      );
      expect(cmd, contains('-i "/in/a.avi"'));
      expect(cmd, contains('-b:v 1242k'));
      expect(cmd, contains('-pass 1'));
      expect(cmd, contains('-passlogfile'));
      expect(cmd, contains('-an'));
      expect(cmd, contains('-f null'));
      expect(cmd, endsWith('"/dev/null"'));
      // pass1 不产出正片：没有音频编码与输出文件
      expect(cmd, isNot(contains('-b:a')));
      expect(cmd, isNot(contains('"/out/a.mp4"')));
    });

    test('pass2：编码遍，maxrate/bufsize 为码率 1.5 倍，AAC 128k + faststart', () {
      final cmd = FfmpegEngine.buildCompressCommand(
        task(
          presetId: FfmpegEngine.compressPresetId,
          duration: 300,
          values: compressValues(),
        ),
        pass: 2,
      );
      expect(cmd, contains('-i "/in/a.avi"'));
      expect(cmd, contains('-b:v 1242k'));
      expect(cmd, contains('-maxrate ${1242 * 1.5 ~/ 1}k')); // 1863
      expect(cmd, contains('-bufsize ${1242 * 1.5 ~/ 1}k'));
      expect(cmd, contains('-pass 2'));
      expect(cmd, contains('-c:a aac'));
      expect(cmd, contains('-b:a 128k'));
      expect(cmd, contains('-movflags +faststart'));
      expect(cmd, endsWith('"/out/a.mp4"'));
    });

    test('音频降档：目标体积小 → -b:a 64k', () {
      // 250 kbps 总码率场景 → 视频码率 181（<300）→ 音频降 64k
      final cmd = FfmpegEngine.buildCompressCommand(
        task(
          presetId: FfmpegEngine.compressPresetId,
          duration: 100,
          values: compressValues(targetMB: '3'), // 3 MiB @100s ≈ 251 kbps
        ),
        pass: 2,
      );
      expect(cmd, contains('-b:a 64k'));
    });

    test('分辨率上限与帧率上限注入', () {
      final cmd = FfmpegEngine.buildCompressCommand(
        task(
          presetId: FfmpegEngine.compressPresetId,
          duration: 300,
          values: compressValues(resolutionCap: '720p', fpsCap: '30'),
        ),
        pass: 2,
      );
      expect(cmd, contains('scale=-2:min(ih,720)'));
      expect(cmd, contains('-r 30'));
    });

    test('裁剪 + 压缩叠加：码率按裁剪后时长计算', () {
      // 50 MiB / 50s（裁剪后） → 总码率 8388.6*0.98-128 ≈ 8093
      final cmd = FfmpegEngine.buildCompressCommand(
        task(
          presetId: FfmpegEngine.compressPresetId,
          duration: 300,
          values: {
            ...compressValues(),
            SettingKey.trimStart: '10',
            SettingKey.trimEnd: '60',
          },
        ),
        pass: 2,
      );
      final kbps = (50 * 1024 * 1024 * 8 / 50 / 1000 * 0.98 - 128).round();
      expect(cmd, contains('-b:v ${kbps}k'));
      expect(cmd, contains('-ss 10'));
      expect(cmd, contains('-t 50'));
    });
  });

  // ---------- 硬件加速压缩命令（MediaCodec 单遍） ----------

  group('硬编命令 buildHardwareCompressCommand', () {
    Map<SettingKey, String> values({String targetMB = '50'}) =>
        {SettingKey.targetVolumeMB: targetMB};

    test('MediaCodec 单遍：无 -pass/-passlogfile/-preset，保留码率三件套', () {
      final cmd = FfmpegEngine.buildHardwareCompressCommand(task(
        presetId: FfmpegEngine.compressPresetId,
        duration: 300,
        values: values(),
      ));
      expect(cmd, contains('-c:v h264_mediacodec'));
      expect(cmd, contains('-b:v 1242k'));
      expect(cmd, contains('-maxrate 1863k'));
      expect(cmd, contains('-bufsize 1863k'));
      // MediaCodec 不支持两遍编码与 -preset
      expect(cmd, isNot(contains('-pass')));
      expect(cmd, isNot(contains('-passlogfile')));
      expect(cmd, isNot(contains('-preset')));
      expect(cmd, contains('-pix_fmt nv12')); // MediaCodec 偏好的输入格式
      expect(cmd, contains('-c:a aac'));
      expect(cmd, contains('-b:a 128k'));
      expect(cmd, contains('-movflags +faststart'));
      expect(cmd, endsWith('"/out/a.mp4"'));
    });

    test('裁剪与分辨率/帧率上限照常注入', () {
      final cmd = FfmpegEngine.buildHardwareCompressCommand(task(
        presetId: FfmpegEngine.compressPresetId,
        duration: 300,
        values: {
          ...values(),
          SettingKey.trimStart: '10',
          SettingKey.trimEnd: '70',
          SettingKey.resolutionCap: '720p',
          SettingKey.fpsCap: '30',
        },
      ));
      expect(cmd, contains('-ss 10'));
      expect(cmd, contains('-t 60'));
      expect(cmd, contains('scale=-2:min(ih,720)'));
      expect(cmd, contains('-r 30'));
    });
  });

  // ---------- buildCommand 路由 ----------

  test('buildCommand 对压缩任务自动路由到 pass2 命令', () {
    final cmd = FfmpegEngine.buildCommand(task(
      presetId: FfmpegEngine.compressPresetId,
      duration: 300,
      values: {SettingKey.targetVolumeMB: '50'},
    ));
    expect(cmd, contains('-pass 2'));
    expect(cmd, endsWith('"/out/a.mp4"'));
  });
}
