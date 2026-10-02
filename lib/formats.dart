import 'models.dart';

/// ============================================================
/// 格式预设目录 —— "想改支持哪些格式"就看这一个文件。
///
/// 每种目标格式 = 一个 FormatPreset：
///   - name / extension      显示名与扩展名
///   - fields                转换设置页上要展示的参数下拉框
///   - buildArgs             如何把用户设置翻译成 FFmpeg 参数
///
/// 想增加新格式：在 formats_data.dart 里照着现有一条复制即可。
/// 想调整某格式编码参数：改它 buildArgs 里的参数数组。
/// ============================================================

/// 参数控件类型：choice = 下拉框；number = 数字输入框（留空=自动）。
enum FieldType { choice, number }

/// 一个可调参数项（在转换设置页渲染成下拉框或数字输入框）。
/// [help] 会显示在控件下方，解释这个选项是干什么的。
class OptionField {
  const OptionField(this.key, this.label, this.options, {this.help})
      : type = FieldType.choice,
        min = null,
        max = null,
        unit = null,
        defaultValue = null;

  const OptionField.number(
    this.key,
    this.label, {
    this.help,
    this.min,
    this.max,
    this.unit,
    this.defaultValue,
  })  : options = const [],
        type = FieldType.number;

  final SettingKey key;
  final String label;
  final FieldType type;

  /// 下拉框选项（choice 类型使用）。
  final List<String> options;

  /// 解释文案（显示在参数下面）。
  final String? help;

  /// 数值范围（number 类型使用，用于输入校验）。
  final int? min;
  final int? max;

  /// 单位后缀，如 "kbps" / "fps"（number 类型显示在输入框后）。
  final String? unit;

  /// number 类型的默认值；null 表示默认留空 = 自动。
  final int? defaultValue;

  /// 界面初始值：下拉框取第一个选项；数字框取默认值（可能为空）。
  String get initialValue {
    if (type == FieldType.number) return defaultValue?.toString() ?? '';
    return options.first;
  }
}

/// 一个目标格式（视频/音频/图片都适用）。
class FormatPreset {
  const FormatPreset({
    required this.id,
    required this.kind,
    required this.name,
    required this.extension,
    required this.description,
    required this.buildArgs,
    this.fields = const [],
    this.extFn,
  });

  final String id;
  final MediaKind kind;
  final String name; // 展示名，如 "MP4"
  final String extension; // 输出扩展名，如 "mp4"
  final String description; // 一行说明，展示在卡片上
  final List<OptionField> fields;

  /// 把用户设置翻译成 FFmpeg 参数列表（不含 -i 和输出路径）。
  final List<String> Function(ConvertSettings s) buildArgs;

  /// "自定义"预设用它根据用户选择的封装格式动态决定扩展名。
  final String? Function(ConvertSettings s)? extFn;

  /// 最终输出扩展名。
  String outExt(ConvertSettings s) => extFn?.call(s) ?? extension;
}

// ---------- 各预设通用的下拉选项 ----------

/// 画面尺寸：数值代表"输出画面最大宽度"，高度按原比例缩放。
const List<String> kResolutionOptions = [
  '原始尺寸',
  '1920 宽',
  '1280 宽',
  '854 宽',
  '640 宽',
];

const List<String> kAudioBitrateOptions = [
  '自动',
  '320k',
  '256k',
  '192k',
  '128k',
  '96k',
];
const List<String> kSampleRateOptions = ['自动', '48000', '44100'];
const List<String> kChannelsOptions = ['自动', '双声道', '单声道'];

/// 仅"自定义"预设使用：
const List<String> kVideoEncoderOptions = [
  'H.264 (libx264)',
  'H.265 (libx265)',
  'VP9 (libvpx-vp9)',
];
const List<String> kAudioEncoderOptions = [
  'AAC',
  'MP3 (libmp3lame)',
  'Opus',
  'Vorbis (OGG)',
  'FLAC',
  'WAV (PCM)',
];
const List<String> kVideoContainerOptions = [
  'MP4',
  'MKV',
  'MOV',
  'WebM',
  'AVI',
  'FLV',
  '3GP',
];
const List<String> kAudioContainerOptions = [
  'M4A (AAC)',
  'MP3',
  'Opus',
  'OGG (Vorbis)',
  'FLAC',
  'WAV',
];
const List<String> kImageContainerOptions = [
  'JPG',
  'PNG',
  'WebP',
  'BMP',
  'TIFF',
  'GIF',
];

// ---------- 各预设要展示的"参数项"公共定义 ----------
// 参数项会原样显示在设置页，help 就是那个选项下面的说明文字。

/// 画面尺寸：限制最大宽度，高度按比例缩放。
const OptionField fieldResolution = OptionField(
  SettingKey.resolution,
  '画面尺寸',
  kResolutionOptions,
  help: '选择输出画面最大宽度，高度按原比例自动缩放；"原始尺寸"不改动画面。',
);

/// 视频质量：CRF 数值，越小越清晰。
const OptionField fieldVideoQuality = OptionField.number(
  SettingKey.videoQuality,
  '视频质量 (CRF)',
  min: 0,
  max: 51,
  defaultValue: 23,
  help: 'CRF 控制画质与文件大小的平衡：数值越小越清晰、文件越大；'
      '常用 18~28，默认 23，留空则由编码器决定。',
);

/// 音频码率。
const OptionField fieldAudioBitrate = OptionField(
  SettingKey.audioBitrate,
  '音频码率',
  kAudioBitrateOptions,
  help: '码率越高音质越好、文件越大；"自动"按格式默认值。',
);

const OptionField fieldSampleRate = OptionField(
  SettingKey.sampleRate,
  '采样率',
  kSampleRateOptions,
  help: '声音每秒采样次数；44100(CD音质)/48000(视频常用)，一般用 44100 即可。',
);

const OptionField fieldChannels = OptionField(
  SettingKey.channels,
  '声道',
  kChannelsOptions,
  help: '双声道=立体声；单声道适合语音/减小体积。',
);

/// 图片质量：1~100，越小压缩越狠、文件越小。
const OptionField fieldImageQuality = OptionField.number(
  SettingKey.imageQuality,
  '图片质量',
  min: 1,
  max: 100,
  defaultValue: 80,
  help: '1~100 的压缩质量：越大越清晰、文件越大；仅对 JPG / WebP 生效。',
);

// ---------- 仅"自定义"预设使用的参数项 ----------

const OptionField fieldVideoBitrate = OptionField.number(
  SettingKey.videoBitrate,
  '视频码率 (kbps)',
  min: 100,
  max: 200000,
  help: '固定码率模式：直接指定每秒数据量（如 2500≈2.5Mbps）。'
      '留空则使用上方 CRF 质量模式。',
);

const OptionField fieldFrameRate = OptionField.number(
  SettingKey.frameRate,
  '帧率 (fps)',
  min: 1,
  max: 120,
  help: '每秒画面帧数：越高越流畅、文件越大。24/25/30 常用，留空保持源帧率。',
);

const OptionField fieldVideoEncoder = OptionField(
  SettingKey.videoEncoder,
  '视频编码器',
  kVideoEncoderOptions,
  help: 'H.264：兼容性最好；H.265：同画质体积更小，老设备可能播不了；'
      'VP9：适合网页（WebM）。',
);

const OptionField fieldAudioEncoder = OptionField(
  SettingKey.audioEncoder,
  '音频编码器',
  kAudioEncoderOptions,
  help: 'AAC 最通用；MP3 兼容最广；Opus 低码率高音质；FLAC/WAV 无损体积大。',
);

const OptionField fieldContainer = OptionField(
  SettingKey.container,
  '封装格式',
  kVideoContainerOptions,
  help: '封装容器决定输出扩展名（MP4/MKV 最常用）。注意与所选编码器兼容：'
      'VP9 建议配 WebM。',
);

/// 仅"仅换容器"预设使用：目标容器 + 不重编码的兼容性提醒。
const OptionField fieldRemuxContainer = OptionField(
  SettingKey.container,
  '目标容器',
  kVideoContainerOptions,
  help: '只换封装、不重新编码，因此必须与源流兼容：'
      'MP4/MKV 最保险；WebM 只收 VP8/VP9/AV1；AVI/FLV/3GP 只收 H.264 系列。',
);

const OptionField fieldContainerImage = OptionField(
  SettingKey.container,
  '图片格式',
  kImageContainerOptions,
  help: '目标图片格式：JPG 有损体积小；PNG 无损带透明；WebP 网页友好；'
      'BMP/TIFF 体积大。',
);

// ---------- 通用参数翻译助手 ----------

/// "1920 宽" -> FFmpeg 缩放滤镜；返回 null 表示不缩放。
String? resolutionToVf(ConvertSettings s) {
  final v = s.of(SettingKey.resolution);
  final width = switch (v) {
    '1920 宽' => '1920',
    '1280 宽' => '1280',
    '854 宽' => '854',
    '640 宽' => '640',
    _ => null,
  };
  if (width == null) return null;
  // -2 表示高度按原比例自动计算并保持为偶数（H.264 要求）
  return 'scale=$width:-2';
}

/// 视频质量 -> CRF 数值（留空/非法时用 23 编码器默认值）。
int videoQualityCrf(ConvertSettings s) {
  final v = int.tryParse(s.of(SettingKey.videoQuality).trim());
  if (v == null) return 23;
  return v.clamp(0, 51);
}

/// 音频通用参数（码率/采样率/声道），全是"自动"时返回 null。
List<String>? audioCommonArgs(ConvertSettings s) {
  final args = <String>[];
  final br = s.of(SettingKey.audioBitrate);
  if (br != '自动') args.addAll(['-b:a', br]);
  final sr = s.of(SettingKey.sampleRate);
  if (sr != '自动') args.addAll(['-ar', sr]);
  final ch = s.of(SettingKey.channels);
  if (ch == '双声道') args.addAll(['-ac', '2']);
  if (ch == '单声道') args.addAll(['-ac', '1']);
  return args.isEmpty ? null : args;
}

/// 图片质量 1~100（留空用 80）。
int imageQualityOf(ConvertSettings s) {
  final v = int.tryParse(s.of(SettingKey.imageQuality).trim());
  if (v == null) return 80;
  return v.clamp(1, 100);
}

/// 图片质量(1~100) -> JPG 的 -q:v（1~8，数字越小越清晰）。
int imageJpegQ(int quality) => ((100 - quality) ~/ 15 + 1).clamp(1, 8);

/// 给参数列表追加画面缩放（若选了非原始尺寸）。
void appendScale(List<String> args, ConvertSettings s) {
  final vf = resolutionToVf(s);
  if (vf != null) args.addAll(['-vf', vf]);
}

/// 追加缩放 + 帧率合成的一个 -vf（自定义用）。
void appendVf(List<String> args, ConvertSettings s) {
  final parts = <String>[];
  final scale = resolutionToVf(s);
  if (scale != null) parts.add(scale);
  final fps = int.tryParse(s.of(SettingKey.frameRate).trim());
  if (fps != null && fps > 0) parts.add('fps=$fps');
  if (parts.isNotEmpty) args.addAll(['-vf', parts.join(',')]);
}

/// 视频码率参数：填了固定码率(kbps)则用 -b:v，否则用 -crf 质量模式。
void appendVideoRate(List<String> args, ConvertSettings s,
    {int crfOffset = 0}) {
  final br = int.tryParse(s.of(SettingKey.videoBitrate).trim());
  if (br != null && br > 0) {
    args.addAll(['-b:v', '${br}k']);
  } else {
    args.addAll(['-crf', '${videoQualityCrf(s) + crfOffset}']);
  }
}

// ---------- "自定义"预设的翻译函数与扩展名映射 ----------

/// 自定义视频：根据用户选的所有参数拼出 FFmpeg 参数。
List<String> customVideoArgs(ConvertSettings s) {
  final args = <String>[];
  final enc = s.of(SettingKey.videoEncoder);

  if (enc.contains('H.265')) {
    args.addAll(['-c:v', 'libx265']);
  } else if (enc.contains('VP9')) {
    args.addAll(['-c:v', 'libvpx-vp9', '-row-mt', '1']);
  } else {
    args.addAll(['-c:v', 'libx264', '-preset', 'medium']);
  }
  args.addAll(['-pix_fmt', 'yuv420p']); // 全设备兼容的像素格式

  appendVf(args, s); // 画面缩放 + 帧率
  appendVideoRate(args, s); // CRF 或固定码率

  // 音频部分
  final aenc = s.of(SettingKey.audioEncoder);
  final isWebm = s.of(SettingKey.container) == 'WebM';
  if (aenc.contains('Opus') || isWebm) {
    args.addAll(['-c:a', 'libopus']);
  } else if (aenc.contains('MP3')) {
    args.addAll(['-c:a', 'libmp3lame']);
  } else if (aenc.contains('FLAC')) {
    args.addAll(['-c:a', 'flac']);
  } else if (aenc.contains('Vorbis')) {
    args.addAll(['-c:a', 'libvorbis']);
  } else {
    args.addAll(['-c:a', 'aac']); // 默认 AAC
  }
  final audioCommon = audioCommonArgs(s);
  if (audioCommon != null) args.addAll(audioCommon);
  // MP4/MOV 家族补 +faststart：与内置 MP4 预设保持一致（边下边播）
  if (isMovContainer(s)) args.addAll(['-movflags', '+faststart']);
  return args;
}

/// 容器是否属于 MP4/MOV 家族（`-movflags +faststart` 只对它们有意义）。
bool isMovContainer(ConvertSettings s) {
  final c = s.of(SettingKey.container);
  return c == 'MP4' || c == 'MOV';
}

/// 自定义视频：封装格式 -> 输出扩展名。
String videoContainerExt(ConvertSettings s) => switch (s.of(SettingKey.container)) {
      'MKV' => 'mkv',
      'MOV' => 'mov',
      'WebM' => 'webm',
      'AVI' => 'avi',
      'FLV' => 'flv',
      '3GP' => '3gp',
      _ => 'mp4',
    };

/// 自定义音频：编码器 -> FFmpeg 参数与扩展名。
({String ext, List<String> args}) customAudioResult(ConvertSettings s) {
  final enc = s.of(SettingKey.audioEncoder);
  final (ext, codec) = switch (enc) {
    'MP3 (libmp3lame)' => ('mp3', <String>['-c:a', 'libmp3lame']),
    'Opus' => ('opus', <String>['-c:a', 'libopus', '-f', 'ogg']),
    'Vorbis (OGG)' => ('ogg', <String>['-c:a', 'libvorbis']),
    'FLAC' => ('flac', <String>['-c:a', 'flac']),
    'WAV (PCM)' => ('wav', <String>['-c:a', 'pcm_s16le']),
    _ => ('m4a', <String>['-c:a', 'aac']),
  };
  final common = audioCommonArgs(s);
  // -vn：音频输出统一丢弃视频流（输入是视频时只取音轨）
  final args = <String>['-vn', ...codec, ...?common];
  return (ext: ext, args: args);
}

/// 自定义图片：容器 -> 扩展名。
String imageContainerExt(ConvertSettings s) => switch (s.of(SettingKey.container)) {
      'PNG' => 'png',
      'WebP' => 'webp',
      'BMP' => 'bmp',
      'TIFF' => 'tiff',
      'GIF' => 'gif',
      _ => 'jpg',
    };

/// 自定义图片：根据容器拼 FFmpeg 参数。
List<String> customImageArgs(ConvertSettings s) {
  final container = s.of(SettingKey.container);
  final args = <String>[];
  final isStatic = container != 'GIF'; // GIF 支持动图，不强制取单帧
  if (isStatic) args.addAll(['-frames:v', '1']);
  appendVf(args, s);
  final codec = switch (container) {
    'PNG' => <String>['-c:v', 'png'],
    'WebP' => <String>['-c:v', 'libwebp', '-quality', '${imageQualityOf(s)}'],
    'BMP' => <String>['-c:v', 'bmp'],
    'TIFF' => <String>['-c:v', 'tiff'],
    'GIF' => <String>['-c:v', 'gif'],
    _ => <String>['-c:v', 'mjpeg', '-q:v', '${imageJpegQ(imageQualityOf(s))}'],
  };
  args.addAll(codec);
  return args;
}
