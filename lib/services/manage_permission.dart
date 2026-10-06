import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

import 'storage_access.dart';

/// "文件管理权限"模式共用助手（设置页 / 转换页 / 脱壳页都会用到）：
///  - Android 11+：请求"所有文件访问"
///  - Android 10 及以下：请求经典存储权限
class ManagePermission {
  ManagePermission._();

  static bool get isAndroid11Plus {
    if (!Platform.isAndroid) return false;
    final v = int.tryParse(Platform.version.split('.').first) ?? 0;
    return v >= 30;
  }

  /// Android 10 及以下：把文件写进公共 `Download/` 需要经典存储权限。
  /// Android 11+ 无需此权限：无权限时会退回 MediaStore 导入（见 StorageAccess）。
  /// 返回是否已可用；不阻塞流程（拿不到就交给 MediaStore 兜底）。
  static Future<bool> ensureLegacyStorageForPublicOutput() async {
    if (!Platform.isAndroid) return true;
    final v = int.tryParse(Platform.version.split('.').first) ?? 0;
    if (v >= 29) return true; // Android 10+ 走 MediaStore，不需要权限
    if (await Permission.storage.isGranted) return true;
    final status = await Permission.storage.request();
    return status.isGranted;
  }

  /// 是否已授予。
  ///
  /// Android 11+ 用原生 Environment.isExternalStorageManager() 权威判定
  ///（permission_handler 在 Android 16 上会漏报：系统设置已授权但插件
  /// 仍显示未授权）；原生判定为未授时再回退插件状态兜底。
  static Future<bool> isGranted() async {
    if (isAndroid11Plus) {
      if (await StorageAccess.isExternalStorageManager()) return true;
      return Permission.manageExternalStorage.isGranted;
    }
    return Permission.storage.isGranted;
  }

  /// 请求授权；被永久拒绝时自动跳系统设置。
  /// 返回最终是否可用（false 表示用户仍未授权，需调用方提示）。
  static Future<bool> ensureGranted() async {
    if (isAndroid11Plus && await isGranted()) return true;
    final perm =
        isAndroid11Plus ? Permission.manageExternalStorage : Permission.storage;
    var status = await perm.status;
    if (!status.isGranted) {
      status = await perm.request();
    }
    if (status.isGranted) return true;
    // 插件仍报未授权时再问一次平台 API（Android 16 兜底）
    if (isAndroid11Plus && await StorageAccess.isExternalStorageManager()) {
      return true;
    }
    if (status.isPermanentlyDenied) {
      await openAppSettings();
    }
    return false;
  }
}
