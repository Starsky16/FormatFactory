import 'package:flutter/services.dart';

/// QQ 音乐 QMC 系列（qmc1 掩码 + qmc2 map/rc4）。
const Set<String> kQmcExtensions = {
  'qmc0', 'qmc2', 'qmc3', 'qmcflac', 'qmcogg',
  'mgg', 'mgg0', 'mgg1', 'mggl',
  'mflac', 'mflac0', 'mflach',
};

/// 酷狗 KGM 系列（纯本地 XOR，无需外部密钥）。
const Set<String> kKgmExtensions = {'kgm', 'kgma', 'vpr'};

/// 酷我 KWM：仅 v1（纯离线 XOR）；v2 需设备密钥，原生侧检测到会明确报错。
const Set<String> kKwmExtensions = {'kwm'};

/// 文件选择/浏览器里允许的全部加密音乐扩展名。
final List<String> kAllUnlockExtensions = [
  'ncm',
  ...kQmcExtensions,
  ...kKgmExtensions,
  ...kKwmExtensions,
];

/// 调 Android 原生"脱壳"通道（MainActivity 里的 com.formatfactory.app/unlock）。
class UnlockApi {
  UnlockApi._();

  static const MethodChannel _channel =
      MethodChannel('com.formatfactory.app/unlock');

  /// 通用脱壳入口：按 [format]（源扩展名）路由到对应原生实现。
  /// 读 [src]，把解出的原始音频写到 [destDir] 目录，返回真实文件路径与扩展名。
  static Future<({String path, String ext})> unlockMusic({
    required String format,
    required String src,
    required String destDir,
  }) async {
    final method = switch (format) {
      'ncm' => 'unlockNcm',
      _ when kQmcExtensions.contains(format) => 'unlockQmc',
      _ when kKgmExtensions.contains(format) => 'unlockKgm',
      _ when kKwmExtensions.contains(format) => 'unlockKwm',
      _ => throw Exception('暂不支持的脱壳格式：.$format'),
    };
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>(
        method,
        {'src': src, 'destDir': destDir, 'format': format},
      );
      if (map == null) {
        throw Exception('无返回结果');
      }
      return (
        path: map['path'] as String,
        ext: map['ext'] as String,
      );
    } on PlatformException catch (e) {
      throw Exception(e.message ?? '解密失败');
    }
  }
}
