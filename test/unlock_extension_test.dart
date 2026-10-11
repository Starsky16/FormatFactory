import 'package:flutter_test/flutter_test.dart';
import 'package:formatfactory/services/unlock_api.dart';

/// Issue #1：双后缀加密文件（如 `xxx.kgm.flac`）的脱壳后缀识别测试。
/// `unlockExtensionOf` 需从右往左扫描各段，跳过真实容器后缀命中加密壳。
void main() {
  group('unlockExtensionOf 双后缀识别', () {
    test('KGM 双后缀取到 kgm', () {
      expect(unlockExtensionOf('/sdcard/a.kgm.flac'), 'kgm');
    });

    test('KGM 变体 kgma 双后缀', () {
      expect(unlockExtensionOf('/sdcard/a.kgma.flac'), 'kgma');
    });

    test('QMC 双后缀取到 qmcflac', () {
      expect(unlockExtensionOf('/sdcard/b.qmcflac.flac'), 'qmcflac');
    });

    test('QMC 双后缀取到 qmc0', () {
      expect(unlockExtensionOf('b.qmc0.mp3'), 'qmc0');
    });

    test('KWM 双后缀取到 kwm', () {
      expect(unlockExtensionOf('/sdcard/c.kwm.flac'), 'kwm');
    });

    test('NCM 双后缀取到 ncm', () {
      expect(unlockExtensionOf('/sdcard/d.ncm.mp3'), 'ncm');
    });
  });

  group('unlockExtensionOf 兼容与退化', () {
    test('单后缀 NCM 正常返回', () {
      expect(unlockExtensionOf('/sdcard/song.ncm'), 'ncm');
    });

    test('无脱壳后缀时退化为最后一个后缀', () {
      expect(unlockExtensionOf('/sdcard/album.flac'), 'flac');
    });

    test('多层后缀取最内层壳', () {
      expect(unlockExtensionOf('/sdcard/album.2020.kgm.flac'), 'kgm');
    });

    test('大写后缀也命中（大小写不敏感）', () {
      expect(unlockExtensionOf('/sdcard/A.KGM.FLAC'), 'kgm');
    });

    test('含目录路径且目录名带点不干扰', () {
      expect(
        unlockExtensionOf('/storage/emulated/0/v1.2/Music/a.kgm.flac'),
        'kgm',
      );
    });

    test('无后缀返回空串', () {
      expect(unlockExtensionOf('/sdcard/README'), '');
    });

    test('空串返回空串', () {
      expect(unlockExtensionOf(''), '');
    });
  });
}
