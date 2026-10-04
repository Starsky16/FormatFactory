import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';

import '../models.dart';

/// 用 FFprobe 读取媒体文件的基本信息（时长、分辨率、编码等）。
class MediaProbe {
  MediaProbe._();

  /// 读取失败（文件损坏/无法识别）时返回 null，由 UI 提示用户。
  static Future<MediaInfo?> probe(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info == null) return null;

      var hasVideo = false;
      var hasAudio = false;
      var hasAttachedPic = false;
      String? videoCodec;
      String? audioCodec;
      int? width;
      int? height;
      // FFprobe 返回的是字符串，转成 int 方便展示
      final bitrate = int.tryParse(info.getBitrate() ?? '');
      final duration = double.tryParse(info.getDuration() ?? '') ?? 0;

      for (final stream in info.getStreams()) {
        final type = stream.getType() ?? '';
        if (type == 'video') {
          hasVideo = true;
          videoCodec ??= stream.getCodec();
          width ??= stream.getWidth();
          height ??= stream.getHeight();
          // disposition.attached_pic == 1 → 该流是内嵌封面而非真实画面
          final disposition = stream.getProperty('disposition');
          if (disposition is Map &&
              disposition['attached_pic']?.toString() == '1') {
            hasAttachedPic = true;
          }
        } else if (type == 'audio') {
          hasAudio = true;
          audioCodec ??= stream.getCodec();
        }
      }

      return MediaInfo(
        durationSeconds: duration,
        hasVideo: hasVideo,
        hasAudio: hasAudio,
        videoCodec: videoCodec,
        audioCodec: audioCodec,
        width: width,
        height: height,
        bitrate: bitrate,
        fileBytes: 0, // 由调用方结合 File 补齐展示（避免同步 IO）
        hasAttachedPic: hasAttachedPic,
      );
    } catch (_) {
      return null;
    }
  }
}
