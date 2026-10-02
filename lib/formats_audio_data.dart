import 'formats.dart';
import 'models.dart';

/// ============================================================
/// 内置【音频】输出格式清单。添加格式同样复制一条改参数即可。
///
/// 约定：每个预设的参数开头都带 `-vn`——这样即使输入是视频，
/// 也只取其中的音轨（见 convert_flow.dart 的 kAudioInputExtensions）。
/// ============================================================

final List<FormatPreset> audioPresets = [
  FormatPreset(
    id: 'audio_mp3',
    kind: MediaKind.audio,
    name: 'MP3',
    extension: 'mp3',
    description: '最通用的音乐格式，任何设备都能播',
    fields: const [fieldAudioBitrate, fieldSampleRate, fieldChannels],
    buildArgs: (s) {
      final args = <String>['-vn', '-c:a', 'libmp3lame'];
      final common = audioCommonArgs(s);
      if (common != null) args.addAll(common);
      return args;
    },
  ),
  FormatPreset(
    id: 'audio_m4a',
    kind: MediaKind.audio,
    name: 'AAC (M4A)',
    extension: 'm4a',
    description: '苹果生态常见格式，同码率音质略好于 MP3',
    fields: const [fieldAudioBitrate, fieldSampleRate, fieldChannels],
    buildArgs: (s) {
      final args = <String>['-vn', '-c:a', 'aac'];
      final common = audioCommonArgs(s);
      if (common != null) args.addAll(common);
      return args;
    },
  ),
  FormatPreset(
    id: 'audio_flac',
    kind: MediaKind.audio,
    name: 'FLAC',
    extension: 'flac',
    description: '无损格式，音质零损失，体积约为 WAV 一半',
    fields: const [fieldSampleRate, fieldChannels],
    buildArgs: (s) {
      final args = <String>['-vn', '-c:a', 'flac'];
      final common = audioCommonArgs(s);
      if (common != null) args.addAll(common);
      return args;
    },
  ),
  FormatPreset(
    id: 'audio_wav',
    kind: MediaKind.audio,
    name: 'WAV',
    extension: 'wav',
    description: '无压缩 PCM，任何软件都能打开，体积很大',
    fields: const [fieldSampleRate, fieldChannels],
    buildArgs: (s) {
      final args = <String>['-vn', '-c:a', 'pcm_s16le'];
      final common = audioCommonArgs(s);
      if (common != null) args.addAll(common);
      return args;
    },
  ),
  FormatPreset(
    id: 'audio_ogg',
    kind: MediaKind.audio,
    name: 'OGG',
    extension: 'ogg',
    description: '开源格式（Vorbis），游戏 / 开源软件常用',
    fields: const [fieldAudioBitrate, fieldSampleRate, fieldChannels],
    buildArgs: (s) {
      final args = <String>['-vn', '-c:a', 'libvorbis'];
      final common = audioCommonArgs(s);
      if (common != null) args.addAll(common);
      return args;
    },
  ),
  FormatPreset(
    id: 'audio_opus',
    kind: MediaKind.audio,
    name: 'Opus',
    extension: 'opus',
    description: '新一代开源格式，低码率音质极佳',
    fields: const [fieldAudioBitrate, fieldChannels],
    buildArgs: (s) {
      final args = <String>['-vn', '-c:a', 'libopus'];
      final common = audioCommonArgs(s);
      if (common != null) args.addAll(common);
      args.addAll(['-f', 'ogg']);
      return args;
    },
  ),
  // 自定义：自由选择音频编码器与各项参数
  FormatPreset(
    id: 'audio_custom',
    kind: MediaKind.audio,
    name: '自定义',
    extension: 'm4a',
    description: '自由选择音频编码器（AAC/MP3/Opus/Vorbis/FLAC/WAV）并调整码率、采样率、声道',
    fields: const [
      fieldAudioEncoder,
      fieldAudioBitrate,
      fieldSampleRate,
      fieldChannels,
    ],
    buildArgs: (s) => customAudioResult(s).args,
    extFn: (s) => customAudioResult(s).ext,
  ),
];
