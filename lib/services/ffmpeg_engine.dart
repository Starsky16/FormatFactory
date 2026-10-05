/// FFmpeg 执行引擎：负责把"任务"翻译成一条 FFmpeg 命令，
/// 并校验底层 FFmpeg 二进制是否就绪。
///
/// 真正"跑起来"的动作在 state/task_queue.dart 里做（串行队列调度），
/// 这里只负责命令拼装和就绪检查，保持单一职责、好读好测。
library;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import '../formats.dart';
import '../formats_data.dart';
import '../models.dart';
import 'bili_cache.dart';
import 'compress_calc.dart';

class FfmpegEngine {
  FfmpegEngine._();

  static bool _ready = false;

  /// 压缩任务的虚拟 presetId：不是真的格式预设，命令走两遍编码专用构建。
  static const String compressPresetId = 'video_compress';

  /// 两遍编码的 passlog 统计文件路径（pass1 写、pass2 读、完成后由队列删除）。
  static String passlogPath(ConvertTask task) => '${task.outputPath}.passlog';

  /// 硬编探测结果缓存（首次进压缩页/任务时探测一次）。
  static bool? _hwEncoderOk;

  /// 设备是否支持 MediaCodec H.264 硬件编码（探测一次后缓存）。
  /// 不支持则压缩自动走软编两遍。
  /// 插件没有查询编码器的 API，跑一次 `-encoders` 从日志解析。
  static Future<bool> hwEncoderAvailable() async {
    final cached = _hwEncoderOk;
    if (cached != null) return cached;
    var ok = false;
    try {
      final session = await FFmpegKit.execute('-hide_banner -encoders');
      final logs = await session.getAllLogsAsString();
      ok = (logs ?? '').contains('h264_mediacodec');
    } catch (_) {
      ok = false;
    }
    _hwEncoderOk = ok;
    return ok;
  }

  /// 压缩命令共用的码率与上限参数（软编/硬编两路共用）。
  ///
  /// 返回 null = 目标体积过小（调用方应报错）。格式：[caps, 码率三件套]。
  static List<String>? _compressRateArgs(ConvertTask task) {
    final s = task.settings;
    final targetMB = int.tryParse(s.of(SettingKey.targetVolumeMB).trim()) ?? 0;
    final dur = effectiveDuration(
      sourceDuration: task.inputDurationSeconds ?? 0,
      trimStart: s.of(SettingKey.trimStart),
      trimEnd: s.of(SettingKey.trimEnd),
    );
    final rates = calcBitrates(
      targetBytes: targetMB * 1024 * 1024,
      durationSeconds: dur,
    );
    if (rates == null) {
      throw ArgumentError('目标体积相对时长太小，无法计算视频码率');
    }

    final args = <String>[];
    // 分辨率/帧率上限（留空 = 不限制）
    final capMatch =
        RegExp(r'(\d+)').firstMatch(s.of(SettingKey.resolutionCap).trim());
    if (capMatch != null) {
      // 高度取 min(ih, N)：不超过上限，也不放大低分辨率源
      args.addAll(['-vf', '"scale=-2:min(ih,${capMatch.group(1)})"']);
    }
    final fps = int.tryParse(s.of(SettingKey.fpsCap).trim());
    if (fps != null && fps > 0) args.addAll(['-r', '$fps']);

    final maxrate = (rates.videoKbps * 1.5).round();
    args.addAll([
      '-b:v', '${rates.videoKbps}k',
      '-maxrate', '${maxrate}k',
      '-bufsize', '${maxrate}k', // 1.5× 码率的缓冲，平滑码率波动
    ]);
    return args;
  }

  /// 支持内嵌封面（attached_pic）的音频容器。WAV 放不下封面；
  /// ogg/opus 理论上支持但各 FFmpeg 版本行为不一，保守不放开。
  static const Set<String> _coverableExts = {'mp3', 'm4a', 'flac'};

  /// 校验 FFmpeg 二进制可用（首次会加载原生库，约 1 秒）。
  static Future<bool> ensureReady() async {
    if (_ready) return true;
    try {
      final version = await FFmpegKitConfig.getFFmpegVersion();
      _ready = (version ?? '').isNotEmpty;
    } catch (_) {
      _ready = false;
    }
    return _ready;
  }

  /// 把任务拼成一条 FFmpeg 命令行字符串。
  ///
  /// 底层引擎支持用引号包裹含空格的路径，这里统一给路径加引号。
  /// 结构：-y [-ss 开始] -i 输入 [第二路输入] [-t 时长] [编码参数...] 输出
  ///  - 普通任务：[inputPath] 一路输入，编码参数来自所选格式预设
  ///  - B站缓存合并（presetId = bili_copy）：两路输入 + "-c copy" 直接封装，不重新编码
  ///  - 压缩任务（presetId = video_compress）：路由到两遍编码命令（pass2）
  ///  - 填了裁剪（trimStart/trimEnd）：`-ss` 注入在 `-i` 之前（输入级 seek），
  ///    `-t` 为裁剪后有效时长；remux+裁剪 = 关键帧粗切
  static String buildCommand(ConvertTask task) {
    if (task.presetId == compressPresetId) {
      return buildCompressCommand(task, pass: 2);
    }
    final preset = presetById(task.kind, task.presetId);
    final secondary = task.mergeAudioPath;
    var args = preset?.buildArgs(task.settings) ??
        (task.presetId == BiliCache.kCopyPresetId
            ? (secondary != null
                ? BiliCache.kMergeCopyArgs
                : BiliCache.kSingleCopyArgs)
            : const <String>[]);

    // JPG 直通：源与目标同为 JPG 且用户没改尺寸/画质时，流复制保住 EXIF
    //（FFmpeg 重编码图片必丢 EXIF，这是唯一可靠的保留路径）
    if (isJpgPassthrough(task)) args = const ['-c:v', 'copy'];

    // 封面保留：源音频带内嵌封面且目标容器装得下时，
    // 显式映射音轨与封面流（封面不重编码），否则默认流选择/-vn 会把封面丢掉
    if (task.kind == MediaKind.audio &&
        task.inputHasAttachedPic &&
        _coverableExts.contains(_extensionOf(task.outputPath))) {
      args = [
        ...args.where((a) => a != '-vn'),
        '-map', '0:a:0',
        '-map', '0:v:0',
        '-c:v', 'copy',
        '-disposition:v:0', 'attached_pic',
      ];
    }

    final trim = _trimInjection(task);
    return [
      '-hide_banner',
      '-y', // 允许覆盖同名输出
      ...?trim?.inputArgs,
      '-i', _quote(task.inputPath),
      if (secondary != null) ...['-i', _quote(secondary)],
      ...?trim?.outputArgs,
      ...args,
      '-map_metadata', '0', // 显式保留源文件的容器级标签（默认行为，防引擎差异）
      _quote(task.outputPath),
    ].join(' ');
  }

  /// 压缩任务的两遍编码命令（presetId = video_compress，软编兜底）。
  ///
  ///   pass 1：分析遍（`-an -f null /dev/null`），生成 passlog 统计文件
  ///   pass 2：按 pass1 的统计精确分配码率，编码正片
  ///
  /// 码率按"目标体积 × 裁剪后时长"反推（[calcBitrates]）；目标体积过小
  /// 抛 ArgumentError——入队前应由 UI 校验，不出垃圾文件。
  static String buildCompressCommand(ConvertTask task, {required int pass}) {
    final audioKbps = _compressAudioKbps(task);
    final videoArgs = [
      ...?_compressRateArgs(task),
      '-c:v', 'libx264',
      '-preset', 'veryfast', // 两遍编码耗时敏感，veryfast 平衡速度与压缩率
      '-pass', '$pass',
      '-passlogfile', _quote(passlogPath(task)),
    ];

    final trim = _trimInjection(task);
    if (pass == 1) {
      return [
        '-hide_banner',
        '-y',
        ...?trim?.inputArgs,
        '-i', _quote(task.inputPath),
        ...?trim?.outputArgs,
        ...videoArgs,
        '-an', // 分析遍不碰音频
        '-f', 'null',
        '"/dev/null"',
      ].join(' ');
    }
    return [
      '-hide_banner',
      '-y',
      ...?trim?.inputArgs,
      '-i', _quote(task.inputPath),
      ...?trim?.outputArgs,
      ...videoArgs,
      '-pix_fmt', 'yuv420p', // 全设备兼容的像素格式
      '-c:a', 'aac',
      '-b:a', '${audioKbps}k',
      '-map_metadata', '0',
      '-movflags', '+faststart', // 压完可直接发微信/边下边播
      _quote(task.outputPath),
    ].join(' ');
  }

  /// 压缩任务的硬件加速命令：MediaCodec H.264 单遍编码。
  ///
  /// 快 5~10 倍，但 MediaCodec 不支持两遍编码（无 -pass/-passlogfile/-preset），
  /// 体积命中精度略降（±15~20%）。设备不支持或执行失败时由队列自动回退
  /// [buildCompressCommand] 软编两遍。
  static String buildHardwareCompressCommand(ConvertTask task) {
    final audioKbps = _compressAudioKbps(task);
    final trim = _trimInjection(task);
    return [
      '-hide_banner',
      '-y',
      ...?trim?.inputArgs,
      '-i', _quote(task.inputPath),
      ...?trim?.outputArgs,
      ...?_compressRateArgs(task),
      '-c:v', 'h264_mediacodec',
      '-pix_fmt', 'nv12', // MediaCodec 编码器偏好的输入像素格式
      '-c:a', 'aac',
      '-b:a', '${audioKbps}k',
      '-map_metadata', '0',
      '-movflags', '+faststart',
      _quote(task.outputPath),
    ].join(' ');
  }

  /// 压缩音频码率：与 [calcBitrates] 同一套降档逻辑（视频码率不足 300k → 64k）。
  static int _compressAudioKbps(ConvertTask task) {
    final s = task.settings;
    final targetMB = int.tryParse(s.of(SettingKey.targetVolumeMB).trim()) ?? 0;
    final dur = effectiveDuration(
      sourceDuration: task.inputDurationSeconds ?? 0,
      trimStart: s.of(SettingKey.trimStart),
      trimEnd: s.of(SettingKey.trimEnd),
    );
    return calcBitrates(
          targetBytes: targetMB * 1024 * 1024,
          durationSeconds: dur,
        )?.audioKbps ??
        128;
  }

  /// 裁剪注入：解析 trimStart/trimEnd，返回要插进命令的参数。
  /// 返回 null = 没有有效裁剪（未填/非法/倒序/覆盖全程），不加任何参数。
  ///   - inputArgs：`-ss 开始`，必须位于 `-i` 之前（输入级 seek）
  ///   - outputArgs：`-t 有效时长`（输出侧限制）
  static ({List<String> inputArgs, List<String> outputArgs})? _trimInjection(
      ConvertTask task) {
    final start = parseClockInput(task.settings.of(SettingKey.trimStart));
    final end = parseClockInput(task.settings.of(SettingKey.trimEnd));
    if (start == null && end == null) return null;

    final src = task.inputDurationSeconds ?? 0;
    if (src > 0) {
      // 与 effectiveDuration 同一套夹取规则：倒序/整体越界 = 无效
      final s = (start ?? 0).clamp(0.0, src);
      final e = (end ?? src).clamp(s, src);
      final dur = e - s;
      // 无效裁剪，或夹取后覆盖全程（不需要裁）→ 都不注入
      if (dur <= 0 || dur >= src) return null;
      return (
        inputArgs: s > 0 ? ['-ss', _num(s)] : const <String>[],
        outputArgs: ['-t', _num(dur)],
      );
    }

    // 没读到源时长时的兜底：结束时刻当作"从头切到该时刻"的时长
    final inputArgs =
        (start != null && start > 0) ? ['-ss', _num(start)] : const <String>[];
    double? dur;
    if (start != null && end != null) {
      final d = end - start;
      dur = d > 0 ? d : null;
    } else if (end != null) {
      dur = end;
    }
    final outputArgs = dur != null ? ['-t', _num(dur)] : const <String>[];
    if (inputArgs.isEmpty && outputArgs.isEmpty) return null;
    return (inputArgs: inputArgs, outputArgs: outputArgs);
  }

  /// 秒数 -> 命令参数文本：整数不带小数点，小数保留 2 位。
  static String _num(double v) {
    if (v == v.roundToDouble()) return v.round().toString();
    return v.toStringAsFixed(2);
  }

  /// JPG 直通判定：图片任务、源与目标同为 JPG、未改尺寸、画质为默认。
  /// 任一条件不满足都走正常重编码（EXIF 会丢，属已知取舍）。
  static bool isJpgPassthrough(ConvertTask task) {
    if (task.kind != MediaKind.image) return false;
    if (_extensionOf(task.inputPath) != 'jpg' ||
        _extensionOf(task.outputPath) != 'jpg') {
      return false;
    }
    return task.settings.of(SettingKey.resolution) == '原始尺寸' &&
        imageQualityOf(task.settings) == 80;
  }

  /// 取路径/文件名的扩展名（小写；无点返回空串）。
  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf('/');
    if (dot < 0 || dot < slash) return '';
    return path.substring(dot + 1).toLowerCase();
  }

  static String _quote(String path) => '"$path"';
}
