import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models.dart';
import '../state/app_settings.dart';
import 'manage_permission.dart';

/// 一次输出的落点解析结果：FFmpeg / 解锁器实际写入 [dir]；
/// [safTreeUri] / [mediaStoreDir] 非空表示转换完成后需要把产物搬运出去。
class OutputTarget {
  const OutputTarget({
    required this.dir,
    this.safTreeUri,
    this.mediaStoreDir,
    this.warning,
  });

  final Directory dir;
  final String? safTreeUri;
  final String? mediaStoreDir;

  /// 非空 = 需要提示用户的降级说明（如自选目录不可写、已退回应用专属目录）。
  final String? warning;
}

/// 一次输出的完整计划：写哪个文件 + 结束后怎么搬运。
class OutputPlan {
  const OutputPlan({
    required this.path,
    this.safTreeUri,
    this.mediaStoreDir,
    this.warning,
  });

  final String path;
  final String? safTreeUri;
  final String? mediaStoreDir;
  final String? warning;

  bool get needsExport => safTreeUri != null || mediaStoreDir != null;
}

/// 输出目录与文件命名工具。
///
/// 三种输出位置（设置页"输出位置"可选）：
///  1. **默认目录**（[AppSettings.targetDefault]）：
///     手机 `Download/FormatExport/<类别>/`，文件管理器里直接可见。
///     - 有存储权限（Android 10 及以下为经典存储权限，11+ 为"所有文件访问"）→ 直接写入；
///     - 没有权限 → 先写内部工作区，成功后由 MediaStore 导入系统下载目录。
///  2. **应用专属目录**（[AppSettings.targetApp]）：
///     `Android/data/<包名>/files/FormatFactory/<类别>/`，免权限，卸载即删。
///  3. **自定义目录**：
///     - SAF `content://…` uri（系统目录选择器）→ 先写工作区再复制进去；
///     - 绝对路径（内建文件浏览器选的）→ 直接写 `<根>/<类别>`。
class FileStore {
  FileStore._();

  /// 公共输出根目录名（位于手机 Download 下）。
  static const String publicDirName = 'FormatExport';

  /// 可写性探针文件名（写在用户的输出目录里，随即删除）。
  static const String probeFileName = '.formatfactory_write_test';

  /// MediaStore 导入用的相对路径：`Download/FormatExport/<类别>`。
  static String mediaStoreDirFor(MediaKind kind) =>
      'Download/$publicDirName/${kind.dirName}';

  /// 应用专属输出目录。
  static Future<Directory> appOutputDir(MediaKind kind) async {
    final base = await _externalDir();
    final dir = Directory(
        '${base.path}${Platform.pathSeparator}FormatFactory'
        '${Platform.pathSeparator}${kind.dirName}');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 内部工作区：需要"先写这里、再搬运"时使用（SAF 目录 / 系统下载目录兜底）。
  static Future<Directory> workDir(MediaKind kind) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(
        '${base.path}${Platform.pathSeparator}FormatFactory_work'
        '${Platform.pathSeparator}${kind.dirName}');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 解析某个设置项对应的输出目标（实际写入目录 + 搬运方式）。
  static Future<OutputTarget> resolve(MediaKind kind, String target) async {
    if (target == AppSettings.targetApp) {
      return OutputTarget(dir: await appOutputDir(kind));
    }
    if (target == AppSettings.targetDefault) {
      return _resolveDefault(kind);
    }
    if (target.startsWith('content://')) {
      // SAF 目录：FFmpeg 写不进 content uri，先落内部工作区
      return OutputTarget(dir: await workDir(kind), safTreeUri: target);
    }
    // 内建文件浏览器选的绝对路径：直接写 <根>/<类别>
    final dir = Directory('$target${Platform.pathSeparator}${kind.dirName}');
    if (await ensureWritable(dir)) return OutputTarget(dir: dir);
    // 没有写权限（如未开启"所有文件访问"）：退回应用专属目录，别让任务白跑
    return OutputTarget(
      dir: await appOutputDir(kind),
      warning: '无法写入所选目录 $target，本次已改存到应用专属目录',
    );
  }

  /// 本进程内已验证过可写的目录（避免每个文件都写一次探针）。
  static final Set<String> _verifiedWritable = {};

  /// 确保 [dir] 存在并且**真的能写**；能写返回 true。
  ///
  /// 只调 `create` 不够：目录已存在但不可写时（只读存储卡、系统受限目录、
  /// 拿了权限又被回收等）`create` 不会报错，问题会拖到 FFmpeg 阶段才以权限错误
  /// 暴露出来。所以这里写一个探针文件验证，写完立刻删掉。
  static Future<bool> ensureWritable(Directory dir) async {
    if (_verifiedWritable.contains(dir.path)) return true;
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      final probe =
          File('${dir.path}${Platform.pathSeparator}$probeFileName');
      await probe.writeAsString('', flush: true);
      await probe.delete();
      _verifiedWritable.add(dir.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 生成一次输出的完整计划（输出文件路径 + 收尾搬运方式）。
  ///
  /// [claimed] 用于同批任务的批内去重：一批里多个同名文件入队时路径是
  /// 一次性生成的，只查磁盘会让第二个同名文件拿到同一路径。
  static Future<OutputPlan> plan(
    MediaKind kind,
    String inputName,
    String presetExtension, {
    required String target,
    Set<String>? claimed,
  }) async {
    final out = await resolve(kind, target);
    return OutputPlan(
      path: pathIn(out.dir, inputName, presetExtension, claimed: claimed),
      safTreeUri: out.safTreeUri,
      mediaStoreDir: out.mediaStoreDir,
      warning: out.warning,
    );
  }

  /// 在 [dir] 里生成输出路径：**优先沿用原文件名**（只换扩展名）；
  /// 目标文件已存在（或在 [claimed] 批内集合里）时追加 `_2`、`_3`… 序号，
  /// 绝不覆盖已有文件。
  static String pathIn(
    Directory dir,
    String inputName,
    String presetExtension, {
    Set<String>? claimed,
  }) {
    final dot = inputName.lastIndexOf('.');
    final base = dot > 0 ? inputName.substring(0, dot) : inputName;
    var candidate = '$base.$presetExtension';
    var n = 2;
    while (true) {
      final path =
          '${dir.path}${Platform.pathSeparator}$candidate';
      if ((claimed == null || !claimed.contains(path)) &&
          !File(path).existsSync()) {
        claimed?.add(path);
        return path;
      }
      candidate = '${base}_$n.$presetExtension';
      n++;
    }
  }

  /// 默认目录：能直写就直写，否则走"内部工作区 + MediaStore 导入"。
  static Future<OutputTarget> _resolveDefault(MediaKind kind) async {
    // Android 10 及以下直写公共 Download 需要经典存储权限（11+ 走 MediaStore，不需要）
    await ManagePermission.ensureLegacyStorageForPublicOutput();
    final direct = await publicDir(kind);
    if (direct != null) return OutputTarget(dir: direct);
    return OutputTarget(
      dir: await workDir(kind),
      mediaStoreDir: mediaStoreDirFor(kind),
    );
  }

  /// 尝试拿到可直接写入的 `Download/FormatExport/<类别>`；拿不到返回 null。
  static Future<Directory?> publicDir(MediaKind kind) async {
    final root = await primaryExternalRoot();
    if (root == null) return null;
    final dir = Directory(
        '${root.path}${Platform.pathSeparator}Download'
        '${Platform.pathSeparator}$publicDirName'
        '${Platform.pathSeparator}${kind.dirName}');
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (_) {
      // Android 10+ 没有"所有文件访问"权限时创建会失败 → 交给 MediaStore
      return null;
    }
  }

  /// 默认输出目录的可读描述（设置页展示用，不触发权限申请）。
  static Future<String> publicDirText(MediaKind kind) async {
    final root = await primaryExternalRoot();
    final base = '${root?.path ?? '/storage/emulated/0'}'
        '${Platform.pathSeparator}Download${Platform.pathSeparator}$publicDirName';
    return '$base${Platform.pathSeparator}${kind.dirName}';
  }

  /// 应用专属输出目录的可读描述（设置页展示用）。
  static Future<String> appOutputDirText() async {
    final base = await _externalDir();
    return '${base.path}${Platform.pathSeparator}FormatFactory';
  }

  /// 手机主存储根目录（`/storage/emulated/0`）。
  /// 由应用专属目录 `/storage/emulated/0/Android/data/<包名>/files` 反推。
  static Future<Directory?> primaryExternalRoot() async {
    final base = await getExternalStorageDirectory();
    if (base == null) return null;
    final i = base.path.indexOf('/Android/');
    if (i > 0) return Directory(base.path.substring(0, i));
    return base.parent; // 非标准环境（桌面 / 测试）兜底
  }

  /// 从文件系统元数据拿文件大小（字节）。
  static int fileBytes(String path) {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  static Future<Directory> _externalDir() async {
    final dir = await getExternalStorageDirectory();
    if (dir == null) {
      throw StateError('无法获取应用外部存储目录');
    }
    return dir;
  }
}