/// 视频压缩 / 裁剪 / 分段的纯计算函数。
///
/// 全部无副作用、不碰 FFmpeg，方便单测：
///   - parseClockInput     容错解析用户输入的起止时间
///   - effectiveDuration   裁剪后的有效时长（越界夹取、非法回退）
///   - calcVideoBitrateKbps 按目标体积反推视频码率（两遍编码用）
///   - segmentBounds       按每段时长切分段边界（可与裁剪叠加）
library;

import '../models.dart';

/// 解析用户输入的时间："1:23:45"=时:分:秒、"12:34"=分:秒、"90"=纯秒。
/// 支持小数秒与首尾空白；任何非法输入（负数、非数字、段数>3）返回 null。
double? parseClockInput(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final parts = text.split(':');
  if (parts.length > 3) return null;
  var seconds = 0.0;
  for (final raw in parts) {
    final v = double.tryParse(raw.trim());
    if (v == null || v < 0) return null;
    seconds = seconds * 60 + v;
  }
  return seconds;
}

/// 裁剪后的有效时长（秒）。
///
/// 规则：
///   - 起止输入各自解析，非法的一边直接忽略（当作没填）
///   - start 夹取到 [0, 源时长]，end 夹取到 [start, 源时长]
///   - 夹取后 end <= start（整体越界或倒序）视为裁剪无效 → 回退源时长
double effectiveDuration({
  required double sourceDuration,
  String? trimStart,
  String? trimEnd,
}) {
  if (sourceDuration <= 0) return 0;
  final start = parseClockInput(trimStart ?? '');
  final end = parseClockInput(trimEnd ?? '');
  final s = (start ?? 0).clamp(0.0, sourceDuration);
  final e = (end ?? sourceDuration).clamp(s, sourceDuration);
  final dur = e - s;
  return dur > 0 ? dur : sourceDuration;
}

/// 视频码率估算内核：目标字节×8 ÷ 时长 ÷ 1000 × (1−2% 封装开销) − 音频码率。
double _videoKbpsOf(int targetBytes, double durationSeconds, int audioKbps) {
  final totalKbps = targetBytes * 8 / durationSeconds / 1000;
  return totalKbps * 0.98 - audioKbps;
}

/// 按目标体积反推视频码率（kbps），两遍编码的 -b:v 用。
///
/// 估算式见 [_videoKbpsOf]；视频码率不足 300k 时音频自动降为 64k 再算一次；
/// 仍不足 100k 说明"目标体积太小"，返回 null（由调用方报错，不出垃圾文件）。
int? calcVideoBitrateKbps({
  required int targetBytes,
  required double durationSeconds,
  int audioKbps = 128,
}) {
  final r = calcBitrates(
    targetBytes: targetBytes,
    durationSeconds: durationSeconds,
    baseAudioKbps: audioKbps,
  );
  return r?.videoKbps;
}

/// 同 [calcVideoBitrateKbps]，但同时给出最终选定的音频码率档位
///（128k 或降档后的 64k），供命令拼装直接使用。
({int videoKbps, int audioKbps})? calcBitrates({
  required int targetBytes,
  required double durationSeconds,
  int baseAudioKbps = 128,
}) {
  if (targetBytes <= 0 || durationSeconds <= 0) return null;
  var video = _videoKbpsOf(targetBytes, durationSeconds, baseAudioKbps);
  var audio = baseAudioKbps;
  if (video < 300 && audio > 64) {
    video = _videoKbpsOf(targetBytes, durationSeconds, 64); // 音频降档，把码率留给画面
    audio = 64;
  }
  if (video < 100) return null; // 目标体积太小，压出来没法看
  return (videoKbps: video.round(), audioKbps: audio);
}

/// 压缩页"目标体积"的默认预填值：约源体积的 40%，向上取整 MB。
/// bytes <= 0（读不到体积）返回 null，界面留空让用户自己填。
int? defaultTargetMB(int bytes) {
  if (bytes <= 0) return null;
  final mb = (bytes * 0.4 / (1024 * 1024)).ceil();
  return mb < 1 ? 1 : mb;
}

/// 压缩效果文案："312 MB → 49.8 MB（−84%）"。
/// 输出体积读不到（<=0）时只显示前半段。
String compressEffectText(int inputBytes, int outputBytes) {
  if (inputBytes <= 0) return '';
  final before = '${formatBytes(inputBytes)} →';
  if (outputBytes <= 0) return '$before ?';
  final pct = ((1 - outputBytes / inputBytes) * 100).round();
  return '$before ${formatBytes(outputBytes)}（−$pct%）';
}

/// 一段的起止时间（秒，相对源文件）。
typedef SegmentRange = ({double start, double end});

/// 按"每段时长"把视频切成 N 段，返回每段 [start, end) 的边界。
///
///   - 先按 [effectiveDuration] 应用裁剪，再在裁剪区间内等分（先裁再分）
///   - 段数 = ceil(有效时长 ÷ 段秒)，末段为余量（可短于段秒）
///   - 段秒 <= 0 或时长 <= 0 属非法输入，返回空列表
List<SegmentRange> segmentBounds({
  required double durationSeconds,
  required double segmentSeconds,
  String? trimStart,
  String? trimEnd,
}) {
  if (segmentSeconds <= 0 || durationSeconds <= 0) return const [];
  // 裁剪区间的绝对起点（夹取后），有效时长见 effectiveDuration
  final start = parseClockInput(trimStart ?? '') ?? 0;
  final s = start.clamp(0.0, durationSeconds).toDouble();
  final eff = effectiveDuration(
    sourceDuration: durationSeconds,
    trimStart: trimStart,
    trimEnd: trimEnd,
  );
  if (eff <= 0) return const [];

  final count = (eff / segmentSeconds).ceil();
  final segs = <SegmentRange>[];
  for (var i = 0; i < count; i++) {
    final segStart = s + i * segmentSeconds;
    final segEnd = (segStart + segmentSeconds).clamp(s, s + eff);
    segs.add((start: segStart, end: segEnd.toDouble()));
  }
  return segs;
}
