import 'dart:convert';
import 'dart:io';

/// ============================================================
/// B站（哔哩哔哩）手机客户端「缓存视频」的解析与合并参数。
///
/// 缓存目录结构（Android，实测 tv.danmaku.bili 2023+ 版本）：
///   download/【视频 id】/
///       c_【cid】/                 （老版本是无前缀的 【cid】）
///           entry.json              视频/分P信息（标题、时长、是否下载完成）
///                                   普通投稿读 page_data，番剧/影视读 ep（index_title / index）
///           cover.jpg / danmaku.xml 封面与弹幕（与本功能无关）
///           【qn 清晰度，如 16/80】/
///               index.json          分片索引（本功能不依赖）
///               video.m4s           视频流（DASH，H.264 / HEVC）
///               audio.m4s           音频流（DASH，AAC）
/// 更老的客户端用 FLV 封装：【cid】/0.blv（视频）+ 1.blv（音频）。
///
/// 本文件只做两件事：
///   1. 扫描目录，把「一路视频 + 一路音频」识别成一个可合并的视频
///   2. 给出「无损直接合并」（-c copy）的 FFmpeg 参数
/// 真正的合并由 FfmpegEngine + 任务队列执行，这里不跑 FFmpeg，方便单测。
/// ============================================================
class BiliCache {
  BiliCache._();

  /// 「无损合并」用的预设 id：不在 formats_*_data.dart 的格式清单里，
  /// FfmpegEngine 见到它就只做封装转换（不重新编码）。
  static const String kCopyPresetId = 'bili_copy';

  /// 双输入（视频 + 音频）无损合并参数。
  /// -map 显式指定，避免某个 m4s 里混入多余轨道时选错流。
  static const List<String> kMergeCopyArgs = [
    '-map', '0:v:0',
    '-map', '1:a:0',
    '-c', 'copy',
    '-movflags', '+faststart',
  ];

  /// 单输入（只有音频流）时的无损参数。
  static const List<String> kSingleCopyArgs = [
    '-c', 'copy',
    '-movflags', '+faststart',
  ];

  /// 常见缓存根目录（B站主客户端 / 国际版）。存在性由调用方判断。
  static const List<String> commonRoots = [
    '/storage/emulated/0/Android/data/tv.danmaku.bili/download',
    '/storage/emulated/0/Android/data/com.bilibili.app.in/download',
  ];

  /// 扫描缓存目录，返回可合并的视频清单。
  ///
  /// 同一个视频若缓存了多个清晰度，只保留清晰度最高的一条（避免重复条目）。
  static Future<List<BiliCacheItem>> scan(String rootPath) async {
    final root = Directory(rootPath);
    if (!await root.exists()) {
      throw Exception('目录不存在或无法访问');
    }
    final best = <String, BiliCacheItem>{};
    await _walk(root, 0, const _Info(), best);
    final list = best.values.toList()
      ..sort((a, b) => a.title.compareTo(b.title));
    return list;
  }

  /// 深度优先扫描：先把目录里出现的 entry.json 合并进上下文，
  /// 一旦发现媒体文件就把「当前目录」当成一个可合并单元，不再向下递归。
  static Future<void> _walk(
    Directory dir,
    int depth,
    _Info info,
    Map<String, BiliCacheItem> out,
  ) async {
    if (depth > 4) return;
    final dirName = _baseName(dir.path);
    if (dirName.isEmpty || dirName.startsWith('.')) return;

    final entry = await _readEntry(dir);
    final ctx = entry == null ? info : info.merge(entry, dir.path);

    List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } catch (_) {
      return; // 没权限 / 目录已消失：跳过
    }

    final media = <File>[];
    final dirs = <Directory>[];
    for (final e in children) {
      if (e is Directory) {
        dirs.add(e);
      } else if (e is File && _isMediaFile(_baseName(e.path))) {
        media.add(e);
      }
    }

    if (media.isNotEmpty) {
      final item = _buildItem(media, ctx, dir);
      if (item != null) {
        // 同一条视频的多个清晰度目录归到同一个 key，只留清晰度最高的
        final key = '${ctx.entryDir ?? dir.path}|${item.title}';
        final old = out[key];
        if (old == null ||
            _qualityRank(dir.path) > _qualityRank(old.sourceDir)) {
          out[key] = item;
        }
      }
      return;
    }
    for (final d in dirs) {
      await _walk(d, depth + 1, ctx, out);
    }
  }

  /// 在一个媒体目录里挑出视频流与音频流。
  static BiliCacheItem? _buildItem(
    List<File> media,
    _Info info,
    Directory dir,
  ) {
    File? video;
    File? audio;
    final sorted = List<File>.from(media)
      ..sort((a, b) => _baseName(a.path).compareTo(_baseName(b.path)));
    for (final f in sorted) {
      final lower = _baseName(f.path).toLowerCase();
      if (lower.contains('audio') || _isIndexed(lower, 1)) {
        audio ??= f; // 同一路出现多个分片文件时只取第一个
      } else if (lower.contains('video') || _isIndexed(lower, 0)) {
        video ??= f;
      } else if (video == null) {
        video = f;
      } else {
        audio ??= f;
      }
    }

    final input = video ?? audio;
    if (input == null) return null;

    final hasVideo = video != null;
    final title =
        info.displayTitle.isNotEmpty ? info.displayTitle : _baseName(dir.path);

    var bytes = 0;
    for (final f in <File?>[if (hasVideo) input, audio]) {
      if (f == null) continue;
      try {
        bytes += f.lengthSync();
      } catch (_) {}
    }

    return BiliCacheItem(
      title: title,
      videoPath: input.path,
      audioPath: hasVideo ? audio?.path : null,
      hasVideo: hasVideo,
      qualityTag: info.quality ?? _baseName(dir.path),
      sizeBytes: bytes,
      complete: info.completed,
      durationSeconds: info.duration,
      sourceDir: dir.path,
    );
  }

  /// 媒体文件扩展名（B站缓存只会出现这几种）。
  static const Set<String> _mediaExtensions = {
    'm4s', 'blv', 'flv', 'mp4', 'm4a', 'mp3', 'aac',
  };

  static bool _isMediaFile(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return _mediaExtensions.contains(name.substring(dot + 1).toLowerCase());
  }

  /// 老版 B站缓存把视频/音频命名成 0.blv / 1.blv（0 = 视频，1 = 音频）。
  static bool _isIndexed(String lowerName, int index) {
    if (!lowerName.startsWith('$index.')) return false;
    final ext = lowerName.substring(2);
    return ext == 'blv' || ext == 'flv' || ext == 'm4s' || ext == 'mp4';
  }

  /// 清晰度排序权重：目录名里的数字（如 16 / 32 / 80）越大画质越高。
  static int _qualityRank(String dirPath) =>
      int.tryParse(_baseName(dirPath)) ?? -1;

  /// 读取目录下的 entry.json（读不到 / 格式异常时返回 null）。
  static Future<Map<String, Object?>?> _readEntry(Directory dir) async {
    final f = File('${dir.path}${Platform.pathSeparator}entry.json');
    try {
      if (!await f.exists()) return null;
      final json = jsonDecode(await f.readAsString());
      if (json is Map<String, Object?>) return json;
      if (json is Map) return json.cast<String, Object?>();
      return null;
    } catch (_) {
      return null;
    }
  }

  static String _baseName(String path) {
    final i = path.lastIndexOf(Platform.pathSeparator);
    return i < 0 ? path : path.substring(i + 1);
  }

  /// 生成安全文件名：去掉文件系统非法字符、压掉换行、截断过长标题。
  static String safeFileName(String title) {
    var s = title
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    while (s.endsWith('.')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.length > 60) s = s.substring(0, 60).trim();
    return s.isEmpty ? 'bili_video' : s;
  }
}

/// 一条「可合并的缓存视频」。
class BiliCacheItem {
  const BiliCacheItem({
    required this.title,
    required this.videoPath,
    required this.audioPath,
    required this.hasVideo,
    required this.qualityTag,
    required this.sizeBytes,
    required this.complete,
    required this.durationSeconds,
    required this.sourceDir,
  });

  /// 展示 / 输出用标题（未做文件名清洗，落盘前用 [BiliCache.safeFileName]）。
  final String title;

  /// 主输入：有视频流时是视频文件，只有音频时是音频文件。
  final String videoPath;

  /// 独立音频流；null 表示源里没有单独音轨（或本来就是纯音频缓存）。
  final String? audioPath;

  /// 是否含视频流（false = 纯音频缓存）。
  final bool hasVideo;

  /// 清晰度展示名，如 "360P"；读不到时用清晰度目录名。
  final String qualityTag;

  /// 视频流 + 音频流的总字节数。
  final int sizeBytes;

  /// entry.json 的 is_completed；false 表示这集可能没下载完。
  final bool complete;

  /// entry.json 的 total_time_milli 换算的时长（秒）；读不到为 null。
  final double? durationSeconds;

  /// 该条目所在目录（列表去重用）。
  final String sourceDir;
}

/// 扫描过程中逐层合并的 entry.json 上下文（内层 entry.json 更精确）。
class _Info {
  const _Info({
    this.title,
    this.part,
    this.page,
    this.quality,
    this.completed = true,
    this.duration,
    this.entryDir,
    this.isEp = false,
  });

  final String? title;
  final String? part;
  final int? page;
  final String? quality;
  final bool completed;
  final double? duration;

  /// 是否来自番剧 / 影视缓存（`ep` 结构）。
  ///
  /// 番剧的分集标题必须一直显示（同一部番的多集在列表里名字都一样），
  /// 普通投稿则只在多分 P 时才带分 P 名 —— 所以要把这个来源记下来。
  final bool isEp;

  /// 最近一次读到的 entry.json 所在目录，用于把同一视频的多清晰度归并。
  final String? entryDir;

  /// 用一份 entry.json 覆盖当前上下文。
  ///
  /// B 站缓存有两种 entry.json 结构，都要认：
  ///  - 普通投稿：`page_data{ part, page, download_title, download_subtitle }`
  ///  - 番剧 / 影视：`ep{ index_title, index }`（没有 page_data，
  ///    只读 page_data 会让番剧缓存拿到空标题、在列表里消失或重名）
  _Info merge(Map<String, Object?> json, String dir) {
    final pageData = json['page_data'];
    final page =
        pageData is Map ? pageData.cast<String, Object?>() : const <String, Object?>{};
    final epData = json['ep'];
    final ep = epData is Map ? epData.cast<String, Object?>() : const <String, Object?>{};
    final epPart = _asText(ep['index_title']);
    final ms = _asInt(json['total_time_milli']);
    final isCompleted = json['is_completed'];
    return _Info(
      title: _asText(json['title']) ??
          _asText(page['download_title']) ??
          title,
      part: _asText(page['part']) ??
          _asText(page['download_subtitle']) ??
          epPart ??
          part,
      page: _asInt(page['page']) ?? _asInt(ep['index']) ?? this.page,
      quality: _asText(json['quality_pithy_description']) ??
          _asText(json['type_tag']) ??
          quality,
      completed: isCompleted is bool ? isCompleted : completed,
      duration: ms != null && ms > 0 ? ms / 1000 : duration,
      entryDir: dir,
      // 清晰度层的 entry.json 通常没有 ep，靠上下文往下传。
      isEp: epPart != null || isEp,
    );
  }

  /// 真正展示的标题：多分P时带上分P名，单P时只用视频标题（避免和分P名重复）。
  ///
  /// 番剧 / 影视例外：每一集都是独立条目，分集标题必须一直带上，
  /// 否则同一部番缓存的多集在列表里会全部重名（且都不带「第 N 话」）。
  String get displayTitle {
    final base = (title ?? '').trim();
    final sub = (part ?? '').trim();
    final no = page ?? 1;
    var name = base.isNotEmpty ? base : sub;
    if (sub.isNotEmpty && sub != name) {
      if (isEp) {
        // ep.index_title 本身一般已含「第 N 话」，不再补 P 号，避免「第1话 … - P1」这种怪名
        name = '$name - $sub';
      } else if (no > 1) {
        name = '$name - P$no $sub';
      }
    }
    return name.trim();
  }

  static String? _asText(Object? v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}');
  }
}
