/// 领域模型：媒体类别、转换设置、转换任务。
/// 全部是纯数据对象，方便看懂、便于测试。
library;

/// 三大媒体类别：对应首页"视频 / 音频 / 图片"三个入口。
enum MediaKind { video, audio, image }

extension MediaKindLabel on MediaKind {
  String get label => switch (this) {
        MediaKind.video => '视频',
        MediaKind.audio => '音频',
        MediaKind.image => '图片',
      };

  /// 用于 FFmpeg 命令里的说明性注释/输出子目录名。
  String get dirName => switch (this) {
        MediaKind.video => 'video',
        MediaKind.audio => 'audio',
        MediaKind.image => 'image',
      };
}

/// 转换设置里可调的参数项（每种目标格式声明自己需要展示哪些项）。
enum SettingKey {
  resolution, // 画面尺寸
  videoQuality, // 视频质量（CRF 数值）
  videoBitrate, // 视频码率 kbps（留空=用 CRF）
  frameRate, // 帧率 fps（留空=保持源）
  videoEncoder, // 视频编码器（自定义用）
  audioEncoder, // 音频编码器（自定义用）
  container, // 封装格式/扩展名（自定义用）
  audioBitrate, // 音频码率
  sampleRate, // 采样率
  channels, // 声道数
  imageQuality, // 图片质量 1~100
}

/// 一次转换的全部用户设置：key -> 选中的选项文本。
class ConvertSettings {
  const ConvertSettings(this.values);

  final Map<SettingKey, String> values;

  static const ConvertSettings empty =
      ConvertSettings(<SettingKey, String>{});

  String of(SettingKey key) => values[key] ?? '';

  /// 简洁展示已选的关键参数（用于任务列表小字说明）。
  /// 数值型字段留空表示"自动"，展示时跳过。
  String get summary {
    final values = this.values.values.where((v) => v.trim().isNotEmpty);
    if (values.isEmpty) return '默认参数';
    return values.join(' · ');
  }
}

/// 单个转换任务的状态。
enum TaskStatus { queued, running, succeeded, failed, canceled }

extension TaskStatusLabel on TaskStatus {
  String get label => switch (this) {
        TaskStatus.queued => '排队中',
        TaskStatus.running => '转换中',
        TaskStatus.succeeded => '完成',
        TaskStatus.failed => '失败',
        TaskStatus.canceled => '已取消',
      };

  bool get isFinished =>
      this == TaskStatus.succeeded ||
      this == TaskStatus.failed ||
      this == TaskStatus.canceled;
}

/// 一次转换任务（加入队列后被串行执行）。
class ConvertTask {
  ConvertTask({
    required this.id,
    required this.kind,
    required this.inputPath,
    required this.inputName,
    required this.presetId,
    required this.presetName,
    required this.settings,
    required this.outputPath,
    required this.createdAt,
    this.unlockFormat,
    this.mergeAudioPath,
    this.safTreeUri,
    this.mediaStoreDir,
    this.inputDurationSeconds,
    this.inputHasAttachedPic = false,
    this.status = TaskStatus.queued,
    this.progress = 0,
    this.error,
  });

  final String id;
  final MediaKind kind;

  /// 若非空 = "脱壳"任务（如 'ncm'），不走 FFmpeg 而是调用原生解密通道。
  final String? unlockFormat;

  /// 若非空 = 该任务要把两路流合成一个文件（B站缓存的 video.m4s + audio.m4s）：
  /// 值为第二路（音频流）路径，主输入见 [inputPath]。
  final String? mergeAudioPath;
  final String inputPath; // 源文件路径
  final String inputName; // 源文件名（展示用）
  final String presetId; // 目标格式 id（见 formats_data.dart）
  final String presetName; // 目标格式名，如 "MP4 (H.264)"
  final ConvertSettings settings;
  final String outputPath; // 输出文件路径
  final DateTime createdAt;

  /// 源时长（秒），FFprobe 读出来用于换算进度百分比。
  final double? inputDurationSeconds;

  /// 源文件的第一个视频流是否是内嵌封面（attached_pic）。
  /// 音频输出映射封面时用：为真时去掉 -vn 并把封面流复制进产物。
  final bool inputHasAttachedPic;

  /// 非空 = 转换完成后要把产物复制进这个"用户自选目录"（SAF content:// uri）。
  final String? safTreeUri;

  /// 非空 = 转换完成后要把产物导入系统"下载"目录下的该相对路径
  /// （形如 `Download/FormatExport/video`）。
  /// 默认输出目录在没有"所有文件访问"权限时走这条路：先写内部工作区，
  /// 成功后由原生端交给 MediaStore 落进公共 Download。
  final String? mediaStoreDir;

  /// 产物是否需要"搬运"到用户可见位置（SAF 目录 / 系统下载目录）。
  bool get needsExport => safTreeUri != null || mediaStoreDir != null;

  final TaskStatus status;

  /// 0.0 ~ 1.0
  final double progress;

  final String? error;

  ConvertTask copyWith({
    TaskStatus? status,
    double? progress,
    String? error,
    bool clearError = false,
    String? outputPath,
    String? mergeAudioPath,
  }) {
    return ConvertTask(
      id: id,
      kind: kind,
      inputPath: inputPath,
      inputName: inputName,
      presetId: presetId,
      presetName: presetName,
      settings: settings,
      outputPath: outputPath ?? this.outputPath,
      createdAt: createdAt,
      unlockFormat: unlockFormat,
      mergeAudioPath: mergeAudioPath ?? this.mergeAudioPath,
      safTreeUri: safTreeUri,
      mediaStoreDir: mediaStoreDir,
      inputDurationSeconds: inputDurationSeconds,
      inputHasAttachedPic: inputHasAttachedPic,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// FFprobe 读出的媒体基本信息（展示在文件列表里）。
class MediaInfo {
  const MediaInfo({
    required this.durationSeconds,
    this.hasVideo = false,
    this.hasAudio = false,
    this.videoCodec,
    this.audioCodec,
    this.width,
    this.height,
    this.bitrate,
    this.fileBytes = 0,
    this.hasAttachedPic = false,
  });

  final double durationSeconds;
  final bool hasVideo;
  final bool hasAudio;
  final String? videoCodec; // 如 h264 / hevc
  final String? audioCodec; // 如 aac / mp3
  final int? width;
  final int? height;
  final int? bitrate; // 位每秒
  final int fileBytes;

  /// 第一个视频流是否为内嵌封面（attached_pic，常见于带封面的音乐文件）。
  /// 音频转码映射封面用；普通视频文件为 false。
  final bool hasAttachedPic;

  String get resolutionText {
    if (width != null && height != null) return '$width×$height';
    if (width != null) return '$width 宽';
    return '未知分辨率';
  }

  String get durationText =>
      durationSeconds > 0 ? formatClock(durationSeconds) : '--:--';

  /// "12:34 · 1920×1080 · h264" 这样的一行摘要。
  String get line {
    if (hasVideo) return '$durationText · $resolutionText · $videoCodec';
    if (hasAudio) return '$durationText · ${audioCodec ?? "未知编码"}';
    return resolutionText;
  }
}

/// 秒 -> "1:23:45" / "12:34"。
String formatClock(double seconds) {
  final total = seconds.round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

