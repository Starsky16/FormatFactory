import 'package:flutter/services.dart';

/// 原生存储能力（见 android MainActivity 里同名的 MethodChannel）：
///  1. 弹系统"选择目录"对话框，返回并持久化 SAF 目录 uri
///  2. 把一个已转好的本地文件复制进该目录（SAF）
///  3. 把一个已转好的本地文件导入系统"下载"目录（MediaStore，Android 10+ 免权限）
class StorageAccess {
  static const MethodChannel _channel =
      MethodChannel('com.starksky16.formatfactory/storage');

  int? _sdkInt;
  StorageAccess._internal();
  static final StorageAccess _instance = StorageAccess._internal();

  /// Android API level（原生 Build.VERSION.SDK_INT 权威判定）。
  ///
  /// ⚠️ dart:io 的 Platform.version 在 Android 上返回的是 Dart 运行时版本
  ///（"3.x…"），拿不到 Android 版本——历史上用它判版本导致 Android 11+
  /// 全被当成 10 及以下处理。启动时（main）调 [warmupSdk] 预热，之后同步读 [sdkInt]。
  static Future<void> warmupSdk() async {
    _instance._sdkInt = await _channel.invokeMethod<int>('sdkInt');
  }

  /// 已预热的 API level；未预热（如单测环境）返回 0。
  static int get sdkInt => _instance._sdkInt ?? 0;

  /// 是否 Android 11+（API 30+）。
  static bool get isAndroid11Plus => sdkInt >= 30;

  /// 权限诊断：一次性导出整条判定链路（原生 checkSelfPermission / AppOps /
  /// 文件系统实测），行列表；失败时返回带失败原因的行（诊断本身不该静默）。
  /// ⚠️ 通道解码回来是 List<Object?>，必须 cast，直接 as List<String?> 会炸。
  static Future<List<String>?> diagnose() async {
    try {
      final raw = await _channel.invokeMethod<List>('diagnose');
      return raw?.cast<String>();
    } catch (e) {
      return ['diagnose通道异常: $e'];
    }
  }

  /// 弹出系统目录选择器；用户取消返回 null。
  static Future<String?> pickDirectory() async {
    return _channel.invokeMethod<String>('pickOutputDir');
  }

  /// "所有文件访问"权威判定（原生 Environment.isExternalStorageManager()）。
  /// Android 16 上 permission_handler 的 AppOps 查询不可靠，必须走平台 API；
  /// 通道异常（如单元测试环境）返回 false 由调用方兜底。
  static Future<bool> isExternalStorageManager() async {
    try {
      return await _channel.invokeMethod<bool>('isExternalStorageManager') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 把 [srcPath] 文件复制到 [treeUri] 目录下，命名为 [fileName]。
  /// 返回目标文件的 content uri；失败返回 null。
  static Future<String?> copyToTree({
    required String treeUri,
    required String fileName,
    required String srcPath,
  }) async {
    try {
      return await _channel.invokeMethod<String>('copyToTree', {
        'treeUri': treeUri,
        'fileName': fileName,
        'srcPath': srcPath,
      });
    } catch (_) {
      return null;
    }
  }

  /// 把 [srcPath] 文件导入系统"下载"目录下的 [relativeDir]
  /// （如 `Download/FormatExport/video`，即手机存储里可见的公共目录）。
  /// 走 MediaStore，因此在 Android 10+ 上**不需要任何存储权限**；
  /// 返回目标文件的 content uri；失败返回 null。
  static Future<String?> copyToDownloads({
    required String relativeDir,
    required String fileName,
    required String srcPath,
  }) async {
    try {
      return await _channel.invokeMethod<String>('copyToDownloads', {
        'relativeDir': relativeDir,
        'fileName': fileName,
        'srcPath': srcPath,
      });
    } catch (_) {
      return null;
    }
  }
}
