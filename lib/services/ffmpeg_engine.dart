/// FFmpeg 执行引擎：负责把"任务"翻译成一条 FFmpeg 命令，
/// 并校验底层 FFmpeg 二进制是否就绪。
///
/// 真正"跑起来"的动作在 state/task_queue.dart 里做（串行队列调度），
/// 这里只负责命令拼装和就绪检查，保持单一职责、好读好测。
library;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';

import '../formats.dart';
import '../formats_data.dart';
import '../models.dart';
import 'bili_cache.dart';

class FfmpegEngine {
  FfmpegEngine._();

  static bool _ready = false;

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
  /// 结构：-y -i 输入 [第二路输入] [编码参数...] 输出
  ///  - 普通任务：[inputPath] 一路输入，编码参数来自所选格式预设
  ///  - B站缓存合并（presetId = bili_copy）：两路输入 + "-c copy" 直接封装，不重新编码
  static String buildCommand(ConvertTask task) {
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

    return [
      '-hide_banner',
      '-y', // 允许覆盖同名输出
      '-i', _quote(task.inputPath),
      if (secondary != null) ...['-i', _quote(secondary)],
      ...args,
      '-map_metadata', '0', // 显式保留源文件的容器级标签（默认行为，防引擎差异）
      _quote(task.outputPath),
    ].join(' ');
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
