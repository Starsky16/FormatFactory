import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:format_factory/models.dart';
import 'package:format_factory/services/file_store.dart';

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

  group('输出文件名', () {
    test('保留原名、加 6 位时间戳、换掉扩展名', () {
      final dir = Directory('/tmp/out');
      final path = FileStore.pathIn(dir, '我的视频.mp4', 'mp3');
      expect(path, startsWith(dir.path));
      expect(path, matches(RegExp(r'我的视频_\d{6}\.mp3$')));
      // 目录路径本身只出现一次
      expect(path.indexOf(dir.path), 0);
    });

    test('没有扩展名的输入也能兜底', () {
      final path = FileStore.pathIn(Directory('/tmp/out'), 'noext', 'mp4');
      expect(path, matches(RegExp(r'noext_\d{6}\.mp4$')));
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