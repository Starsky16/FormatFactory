import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:format_factory/models.dart';
import 'package:format_factory/services/bili_cache.dart';
import 'package:format_factory/services/ffmpeg_engine.dart';
import 'package:path/path.dart' as p;

/// B站缓存解析 + 合并命令拼装的单元测试。
/// 用临时目录搭出真实缓存结构（entry.json + 清晰度目录 + video.m4s/audio.m4s）。
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bili_cache_test');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  void writeFile(String relative, [String content = 'data']) {
    final f = File(p.join(root.path, relative));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  void writeEntry(String relativeDir, Map<String, Object?> json) =>
      writeFile(p.join(relativeDir, 'entry.json'), jsonEncode(json));

  Map<String, Object?> entryJson({
    String title = '测试视频',
    String part = '第一讲',
    int page = 1,
    int ms = 2448921,
    String quality = '360P',
    bool completed = true,
  }) =>
      <String, Object?>{
        'title': title,
        'is_completed': completed,
        'total_time_milli': ms,
        'quality_pithy_description': quality,
        'page_data': <String, Object?>{
          'part': part,
          'page': page,
          'download_title': title,
        },
      };

  test('标准 DASH 缓存：识别视频流 + 音频流并读出标题/时长', () async {
    writeEntry('114087971265806/c_25763846981', entryJson());
    writeFile('114087971265806/c_25763846981/cover.jpg');
    writeFile('114087971265806/c_25763846981/16/index.json', '{}');
    writeFile('114087971265806/c_25763846981/16/video.m4s', '0123456789');
    writeFile('114087971265806/c_25763846981/16/audio.m4s', '01234');

    final items = await BiliCache.scan(root.path);

    expect(items, hasLength(1));
    final item = items.single;
    expect(item.title, '测试视频');
    expect(item.hasVideo, isTrue);
    expect(item.qualityTag, '360P');
    expect(item.complete, isTrue);
    expect(item.durationSeconds, closeTo(2448.921, 0.001));
    expect(item.videoPath, endsWith(p.join('16', 'video.m4s')));
    expect(item.audioPath, endsWith(p.join('16', 'audio.m4s')));
    expect(item.sizeBytes, 15);
  });

  test('同一视频缓存多个清晰度：只保留清晰度最高的一条', () async {
    writeEntry('104001/c_1', entryJson(title: '多清晰度'));
    for (final q in ['16', '32', '80']) {
      writeFile('104001/c_1/$q/video.m4s', 'v');
      writeFile('104001/c_1/$q/audio.m4s', 'a');
    }
    final items = await BiliCache.scan(root.path);
    expect(items, hasLength(1));
    expect(items.single.videoPath, endsWith(p.join('80', 'video.m4s')));
  });

  test('旧版 0.blv / 1.blv 命名也能识别', () async {
    writeEntry('999', entryJson(title: '老缓存', quality: ''));
    writeFile('999/0.blv', 'v');
    writeFile('999/1.blv', 'a');
    final item = (await BiliCache.scan(root.path)).single;
    expect(item.hasVideo, isTrue);
    expect(item.videoPath, endsWith('0.blv'));
    expect(item.audioPath, endsWith('1.blv'));
    expect(item.qualityTag, '999'); // 条目里没有清晰度 → 退回清晰度目录名
  });

  test('番剧缓存（ep 结构）：读出分集标题与集号，标题带上分集名', () async {
    // 番剧没有 page_data，分集信息在 ep{index_title, index} 里
    writeEntry('104001', <String, Object?>{
      'title': '某番剧',
      'type_tag': '番剧',
      'is_completed': true,
      'total_time_milli': 1440000,
      'ep': <String, Object?>{'index_title': '第1话 出发', 'index': 1},
    });
    writeFile('104001/16/video.m4s', '0123456789');
    writeFile('104001/16/audio.m4s', '01234');

    final item = (await BiliCache.scan(root.path)).single;

    // 集号是 1（不是多分P），但番剧必须把分集名带出来，否则多集重名
    expect(item.title, '某番剧 - 第1话 出发');
    expect(item.durationSeconds, closeTo(1440, 0.001));
    expect(item.hasVideo, isTrue);
    expect(item.audioPath, isNotNull);
  });

  test('番剧缓存：分集信息在外层、清晰度层 entry.json 没有 ep 时也能继承', () async {
    writeEntry('104002', <String, Object?>{
      'title': '某番剧 第二季',
      'ep': <String, Object?>{'index_title': '第3话 重逢', 'index': 3},
    });
    // 清晰度层的 entry.json 通常只有清晰度/完成度，没有 ep
    writeEntry('104002/c_1', <String, Object?>{
      'is_completed': false,
      'total_time_milli': 600000,
      'quality_pithy_description': '1080P',
    });
    writeFile('104002/c_1/80/video.m4s', 'v');
    writeFile('104002/c_1/80/audio.m4s', 'a');

    final item = (await BiliCache.scan(root.path)).single;

    expect(item.title, '某番剧 第二季 - 第3话 重逢');
    expect(item.qualityTag, '1080P');
    expect(item.complete, isFalse);
  });

  test('普通投稿不带 ep 时行为不变：单P只用视频标题', () async {
    writeEntry('100/c_1', entryJson(title: '普通视频', part: '分P名', page: 1));
    writeFile('100/c_1/16/video.m4s', 'v');
    writeFile('100/c_1/16/audio.m4s', 'a');

    // page=1 且非番剧 → 不带后缀（避免与视频标题重复）
    expect((await BiliCache.scan(root.path)).single.title, '普通视频');
  });

  test('只有音频的缓存：标记为没有视频流', () async {
    writeEntry('100/c_1', entryJson(title: '纯音频'));
    writeFile('100/c_1/16/audio.m4s', 'a');
    final item = (await BiliCache.scan(root.path)).single;
    expect(item.hasVideo, isFalse);
    expect(item.audioPath, isNull);
    expect(item.videoPath, endsWith('audio.m4s'));
  });

  test('多分P会把分P名带进标题', () async {
    writeEntry('200/c_2', entryJson(title: '合集', part: '第二讲', page: 2));
    writeFile('200/c_2/32/video.m4s', 'v');
    writeFile('200/c_2/32/audio.m4s', 'a');
    expect((await BiliCache.scan(root.path)).single.title, '合集 - P2 第二讲');
  });

  test('没下载完的缓存会标记 complete=false', () async {
    writeEntry('300/c_3', entryJson(title: '没下完', completed: false));
    writeFile('300/c_3/16/video.m4s', 'v');
    writeFile('300/c_3/16/audio.m4s', 'a');
    expect((await BiliCache.scan(root.path)).single.complete, isFalse);
  });

  test('不是缓存目录时返回空列表（不抛异常）', () async {
    writeFile('empty/readme.txt');
    expect(await BiliCache.scan(root.path), isEmpty);
  });

  test('safeFileName 清掉非法字符、兜底并截断', () {
    expect(BiliCache.safeFileName('a/b:c*d?e"f<g>h|i'), 'a_b_c_d_e_f_g_h_i');
    expect(BiliCache.safeFileName('   '), 'bili_video');
    final long = List<String>.filled(200, 'x').join();
    expect(BiliCache.safeFileName(long).length, 60);
  });

  ConvertTask copyTask({String? audioPath}) => ConvertTask(
        id: 't1',
        kind: MediaKind.video,
        inputPath: '/cache/16/video.m4s',
        inputName: '视频.mp4',
        presetId: BiliCache.kCopyPresetId,
        presetName: 'MP4（缓存合并）',
        settings: ConvertSettings.empty,
        outputPath: '/out/视频.mp4',
        createdAt: DateTime(2026, 1, 1),
        mergeAudioPath: audioPath,
      );

  test('合并命令：两路输入 + -c copy，不重新编码', () {
    final cmd = FfmpegEngine.buildCommand(copyTask(audioPath: '/cache/16/audio.m4s'));
    expect(cmd, contains('-i "/cache/16/video.m4s"'));
    expect(cmd, contains('-i "/cache/16/audio.m4s"'));
    expect(cmd, contains('-map 0:v:0'));
    expect(cmd, contains('-map 1:a:0'));
    expect(cmd, contains('-c copy'));
    expect(cmd, endsWith('"/out/视频.mp4"'));
  });

  test('只有一路输入时不加流选择 -map，避免选流失败', () {
    final cmd = FfmpegEngine.buildCommand(copyTask());
    expect(cmd, contains('-i "/cache/16/video.m4s"'));
    // 注意：-map_metadata 0 是标签映射不是流选择，允许出现
    expect(cmd, isNot(contains('-map ')));
    expect(cmd, contains('-c copy'));
  });

  test('普通格式预设不受 B站合并逻辑影响', () {
    final task = ConvertTask(
      id: 't2',
      kind: MediaKind.video,
      inputPath: '/in/a.avi',
      inputName: 'a.avi',
      presetId: 'mp4_h264',
      presetName: 'MP4 (H.264)',
      settings: ConvertSettings({SettingKey.videoQuality: '23'}),
      outputPath: '/out/a.mp4',
      createdAt: DateTime(2026, 1, 1),
    );
    final cmd = FfmpegEngine.buildCommand(task);
    expect(cmd, contains('"/in/a.avi"'));
    expect(cmd, isNot(contains('-map 0:v:0')));
    expect(cmd, isNot(contains('-c copy')));
  });
}
