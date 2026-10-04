import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

/// SharedPreferences 单例：在 main() 里 await 后通过 override 注入，
/// 让设置 Provider 可以同步读取，避免到处异步。
final sharedPrefsProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('sharedPrefsProvider 必须在 ProviderScope 中 override');
});

/// 应用设置。
///
/// 输出目标（见 [targetOf]，所有媒体类别共用）：
///  - [targetDefault] = 手机 `Download/FormatExport/<类别>/`（默认，文件管理器可见）
///  - [targetApp]     = 应用专属目录（免权限，卸载即删）
///  - 一段 `content://…` SAF 目录 uri，或"内建文件浏览器"选中的绝对路径
/// [pickerMode]：'saf' = 系统文件选择器（默认）；'manage' = 文件管理权限 + 自建浏览器。
/// [dirPickerMode]：选择"自定义输出目录"时用哪种方式，取值同为 'saf' / 'manage'。
class AppSettings {
  const AppSettings({
    required this.pickerMode,
    required this.outputTarget,
    this.dirPickerMode = 'saf',
    this.notificationsEnabled = true,
    this.concurrentTasks = 1,
  });

  final String pickerMode;
  final String outputTarget;

  /// 选择"自定义输出目录"的方式：
  /// 'saf' = 系统目录选择器（免权限）；'manage' = 内建文件浏览器（需文件管理权限）。
  final String dirPickerMode;

  /// 转码时是否显示通知 + 保持后台运行。
  final bool notificationsEnabled;

  /// 同时执行的任务数（并行度），1 = 串行。
  final int concurrentTasks;

  /// 默认输出目录：手机 `Download/FormatExport/<类别>/`。
  /// 有存储权限时直接写入；没有时由 MediaStore 导入（见 FileStore / StorageAccess）。
  static const String targetDefault = 'default';

  /// 应用专属目录：`Android/data/<包名>/files/FormatFactory/<类别>/`。
  static const String targetApp = 'app';

  /// 输出目标按类别仍落在各自子目录（`<目标>/<类别>/`），
  /// 这里只是返回统一的目标值。
  String targetOf(MediaKind kind) => outputTarget;

  AppSettings copyWith({
    String? pickerMode,
    String? dirPickerMode,
    String? outputTarget,
    bool? notificationsEnabled,
    int? concurrentTasks,
  }) {
    return AppSettings(
      pickerMode: pickerMode ?? this.pickerMode,
      dirPickerMode: dirPickerMode ?? this.dirPickerMode,
      outputTarget: outputTarget ?? this.outputTarget,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      concurrentTasks: concurrentTasks ?? this.concurrentTasks,
    );
  }
}

final appSettingsProvider =
    NotifierProvider<AppSettingsNotifier, AppSettings>(AppSettingsNotifier.new);

class AppSettingsNotifier extends Notifier<AppSettings> {
  static const _kPicker = 'picker.mode';
  static const _kDirPicker = 'out.picker';
  static const _kTarget = 'out.target';
  // 旧版按类别分设的三个键，仅用于一次性迁移读取
  static const _kV = 'out.video';
  static const _kA = 'out.audio';
  static const _kI = 'out.image';
  static const _kNotify = 'notify.enabled';
  static const _kConcurrent = 'queue.concurrent';

  @override
  AppSettings build() {
    final p = ref.watch(sharedPrefsProvider);
    // 迁移：旧版三类设置完全一致 → 沿用；否则（含从未设置）→ 默认目录
    final v = p.getString(_kV);
    final a = p.getString(_kA);
    final i = p.getString(_kI);
    final legacy = (v != null && v == a && a == i) ? v : null;
    return AppSettings(
      pickerMode: p.getString(_kPicker) ?? 'saf',
      dirPickerMode: p.getString(_kDirPicker) ?? 'saf',
      outputTarget:
          p.getString(_kTarget) ?? legacy ?? AppSettings.targetDefault,
      notificationsEnabled: p.getBool(_kNotify) ?? true,
      concurrentTasks: p.getInt(_kConcurrent) ?? 1,
    );
  }

  /// 切换读取文件方式：'saf' / 'manage'。
  Future<void> setPickerMode(String mode) async {
    state = state.copyWith(pickerMode: mode);
    await _persist();
  }

  /// 切换"自定义输出目录"的选择方式：'saf' / 'manage'。
  Future<void> setDirPickerMode(String mode) async {
    state = state.copyWith(dirPickerMode: mode);
    await _persist();
  }

  /// 设置输出目标（所有媒体类别共用）
  /// （[AppSettings.targetDefault] / [AppSettings.targetApp] / SAF uri / 绝对路径）。
  /// [kind] 仅保留兼容旧调用签名，不再区分类别。
  Future<void> setOutput(MediaKind kind, String target) async {
    state = state.copyWith(outputTarget: target);
    await _persist();
  }

  /// 通知（后台进度条）开关。
  Future<void> setNotificationsEnabled(bool enabled) async {
    state = state.copyWith(notificationsEnabled: enabled);
    await _persist();
  }

  /// 设置并行任务数（1~8）。
  Future<void> setConcurrentTasks(int n) async {
    state = state.copyWith(concurrentTasks: n.clamp(1, 8));
    await _persist();
  }

  Future<void> _persist() async {
    final p = ref.read(sharedPrefsProvider);
    await p.setString(_kPicker, state.pickerMode);
    await p.setString(_kDirPicker, state.dirPickerMode);
    await p.setString(_kTarget, state.outputTarget);
    await p.setBool(_kNotify, state.notificationsEnabled);
    await p.setInt(_kConcurrent, state.concurrentTasks);
  }
}
