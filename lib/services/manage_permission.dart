import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

import 'storage_access.dart';

/// "文件管理权限"模式共用助手（设置页 / 转换页 / 脱壳页都会用到）。
///
/// 判定按系统版本**彻底两套逻辑**、互不混用（单一事实源）：
///  - Android 11+：只信原生 Environment.isExternalStorageManager()。
///    permission_handler 的 AppOps 查询在高版本上不可靠
///    （Android 16 实测：系统已授权但插件仍报 denied），一律不兜底。
///  - Android 10 及以下：只走 permission_handler 的经典存储权限。
class ManagePermission {
  ManagePermission._();

  /// 是否 Android 11+（API 30+）。判定源 = 原生 Build.VERSION.SDK_INT
  ///（经 StorageAccess 预热缓存）——dart:io 的 Platform.version 在 Android
  /// 上返回的是 Dart 运行时版本（"3.x…"），绝不能用它判系统版本。
  static bool get isAndroid11Plus => StorageAccess.isAndroid11Plus;

  /// Android 10 及以下：把文件写进公共 `Download/` 需要经典存储权限。
  /// Android 11+ 无需此权限：无权限时会退回 MediaStore 导入（见 StorageAccess）。
  /// 返回是否已可用；不阻塞流程（拿不到就交给 MediaStore 兜底）。
  static Future<bool> ensureLegacyStorageForPublicOutput() async {
    if (!Platform.isAndroid) return true;
    if (StorageAccess.sdkInt >= 29) return true; // Android 10+ 走 MediaStore
    if (await canReadSharedStorage()) return true;
    final status = await Permission.storage.request();
    return status.isGranted && await canReadSharedStorage();
  }

  /// 实测共享存储可读（Android 10 及以下低版本的**权威判定源**）。
  ///
  /// 背景：鸿蒙 4.0（Android 9）实测 permission_handler 报 storage 已授权、
  /// 但 Directory.list() 仍 errno 13 ——插件状态可能与系统真实授权不符
  ///（尤其经系统设置页授权后，进程的存储补充组要完全重启应用才刷新）。
  /// 因此低版本判定一律试读公共存储根目录，不采信插件状态。
  static Future<bool> canReadSharedStorage() async {
    if (!Platform.isAndroid) return true;
    try {
      Directory('/storage/emulated/0/').listSync(followLinks: false).take(1);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 是否已授予（Android 11+ 走原生 API，低版本走实测）。
  static Future<bool> isGranted() async {
    if (isAndroid11Plus) return StorageAccess.isExternalStorageManager();
    return canReadSharedStorage();
  }

  /// 请求授权；返回最终是否可用（false 表示用户仍未授权，需调用方提示）。
  static Future<bool> ensureGranted() async {
    if (isAndroid11Plus) {
      if (await StorageAccess.isExternalStorageManager()) return true;
      // 系统授权开关页只有这里能拉起；返回后调用方再问一次 isGranted()
      await Permission.manageExternalStorage.request();
      return StorageAccess.isExternalStorageManager();
    }
    if (await canReadSharedStorage()) return true;
    var status = await Permission.storage.request();
    if (!status.isGranted) status = await Permission.storage.request();
    // 插件报了授权仍要实测确认（状态误报/进程组未刷新都拦在这里）
    return status.isGranted && await canReadSharedStorage();
  }
}
