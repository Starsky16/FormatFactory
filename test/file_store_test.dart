import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:formatfactory/models.dart';
import 'package:formatfactory/services/file_store.dart';

/// P4 输出目录改造的纯函数部分（不依赖 path_provider / 原生通道）。
void main() {
  group('默认输出目录口径', () {
    test('三类都落在 Download/FormatExport/<kind>', () {
      expect(FileStore.publicDirName, 'FormatExport');
      expect(FileStore.mediaStoreDirFor(MediaKind.video),
          'Download/FormatExport/video');
      expect(FileStore.mediaStoreDirFor(MediaKind.audio),
          'Download/FormatExport/audio');
      expect(FileStore.mediaStoreDirFor(MediaKind.image),
          'Download/FormatExport/image');
    });

    test('mediaStoreDirFor 与 MediaKind.dirName 保持一致', () {
      for (final kind in MediaKind.values) {
        expect(FileStore.mediaStoreDirFor(kind), endsWith('/${kind.dirName}'));
      }
    });
  });

  group('输出文件名（原名优先，重名加序号）', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('ff_naming');
      addTearDown(() => dir.deleteSync(recursive: true));
    });

    test('目录空闲时保留原名，只换扩展名', () {
      final path = FileStore.pathIn(dir, '我的视频.mp4', 'mp3');
      expect(path, '${dir.path}${Platform.pathSeparator}我的视频.mp3');
    });

    test('重名时加 _2 序号，不覆盖已有文件', () {
      File('${dir.path}${Platform.pathSeparator}song.mp3')
          .writeAsStringSync('x');
      final path = FileStore.pathIn(dir, 'song.flac', 'mp3');
      expect(path, '${dir.path}${Platform.pathSeparator}song_2.mp3');
    });

    test('序号被占时继续递增到 _3', () {
      for (final name in ['song.mp3', 'song_2.mp3']) {
        File('${dir.path}${Platform.pathSeparator}$name').writeAsStringSync('x');
      }
      final path = FileStore.pathIn(dir, 'song.flac', 'mp3');
      expect(path, '${dir.path}${Platform.pathSeparator}song_3.mp3');
    });

    test('claimed 集合内的路径视为已占用，选中的路径会回填', () {
      final claimed = <String>{};
      final first = FileStore.pathIn(dir, 'song.flac', 'mp3', claimed: claimed);
      final second =
          FileStore.pathIn(dir, 'song.flac', 'mp3', claimed: claimed);
      expect(first, '${dir.path}${Platform.pathSeparator}song.mp3');
      expect(second, '${dir.path}${Platform.pathSeparator}song_2.mp3');
      expect(claimed, containsAll([first, second]));
    });

    test('没有扩展名的输入也能兜底', () {
      final path = FileStore.pathIn(dir, 'noext', 'mp4');
      expect(path, '${dir.path}${Platform.pathSeparator}noext.mp4');
    });
  });

  group('ensureWritable（自选目录可写性探针）', () {
    test('可写目录返回 true 且不留探针文件', () async {
      final dir = Directory.systemTemp.createTempSync('ff_writable');
      addTearDown(() => dir.deleteSync(recursive: true));

      expect(await FileStore.ensureWritable(dir), isTrue);
      final leftovers = dir
          .listSync()
          .where((e) => e.path.contains(FileStore.probeFileName))
          .toList();
      expect(leftovers, isEmpty, reason: '探针文件必须自行删掉');
    });

    test('目录不存在时会先建出来', () async {
      final base = Directory.systemTemp.createTempSync('ff_writable');
      addTearDown(() => base.deleteSync(recursive: true));
      final sub = Directory(
          '${base.path}${Platform.pathSeparator}a${Platform.pathSeparator}b');

      expect(await FileStore.ensureWritable(sub), isTrue);
      expect(sub.existsSync(), isTrue);
    });

    test('路径被同名文件占住时返回 false（不抛异常）', () async {
      final base = Directory.systemTemp.createTempSync('ff_writable');
      addTearDown(() => base.deleteSync(recursive: true));
      final blocker = File('${base.path}${Platform.pathSeparator}blocker')
        ..writeAsStringSync('x');

      expect(await FileStore.ensureWritable(Directory(blocker.path)), isFalse);
    });
  });

  group('OutputPlan', () {
    test('needsExport 只在需要搬运时为真', () {
      const none = OutputPlan(path: '/a/b.mp4');
      expect(none.needsExport, isFalse);
      const saf = OutputPlan(path: '/a/b.mp4', safTreeUri: 'content://tree/1');
      expect(saf.needsExport, isTrue);
      const mediaStore =
          OutputPlan(path: '/a/b.mp4', mediaStoreDir: 'Download/FormatExport/video');
      expect(mediaStore.needsExport, isTrue);
    });
  });
}