import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models.dart';
import '../services/file_store.dart';
import '../services/manage_permission.dart';
import '../services/storage_access.dart';
import '../state/app_settings.dart';
import 'file_browser_page.dart';

/// 设置页：输出位置 + 读取文件方式。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  /// "文件管理权限"模式当前的授权状态。
  PermissionStatus? _manageStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshPermission();
    });
  }

  static bool get _isAndroid11Plus {
    if (!Platform.isAndroid) return false;
    final v = int.tryParse(Platform.version.split('.').first) ?? 0;
    return v >= 30; // Android 11 = API 30
  }

  static Future<PermissionStatus> _permStatus() async {
    if (_isAndroid11Plus) {
      // Android 16 上 permission_handler 的 AppOps 查询漏报
      //（系统已授权但插件仍报 denied），必须用平台 API 权威判定
      final native = await StorageAccess.isExternalStorageManager();
      if (native) return Future.value(PermissionStatus.granted);
      return Permission.manageExternalStorage.status;
    }
    return Permission.storage.status; // Android 10 及以下
  }

  Future<void> _refreshPermission() async {
    if (!Platform.isAndroid) return; // 仅 Android 才有文件权限概念
    final s = await _permStatus();
    if (mounted) setState(() => _manageStatus = s);
  }

  /// 请求"所有文件访问"权限。
  Future<void> _grantManage() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_isAndroid11Plus) {
      if (await StorageAccess.isExternalStorageManager()) {
        await _refreshPermission();
        messenger.showSnackBar(const SnackBar(content: Text('已获得文件访问权限')));
        return;
      }
      final s = await Permission.manageExternalStorage.request();
      // Android 16 兜底：插件状态可能漏报，再问一次平台 API
      final native = await StorageAccess.isExternalStorageManager();
      await _refreshPermission();
      if (s.isGranted || native) {
        messenger.showSnackBar(const SnackBar(content: Text('已获得文件访问权限')));
        return;
      }
      if (s.isPermanentlyDenied) {
        await openAppSettings();
        messenger.showSnackBar(const SnackBar(
          content: Text('请在系统设置中开启"所有文件访问"后再返回本页重试'),
        ));
      } else {
        messenger.showSnackBar(const SnackBar(
          content: Text('未授权。你可以在系统设置中开启后再试'),
        ));
      }
      return;
    }
    final s = await Permission.storage.request();
    await _refreshPermission();

    if (s.isGranted) {
      messenger.showSnackBar(const SnackBar(content: Text('已获得文件访问权限')));
      return;
    }
    // Android 9 及以下：若被永久拒绝，引导去系统设置开启
    if (s.isPermanentlyDenied) {
      await openAppSettings();
      messenger.showSnackBar(const SnackBar(
        content: Text('请在系统设置中打开"存储"权限后再返回本页重试'),
      ));
    } else {
      messenger.showSnackBar(const SnackBar(
        content: Text('未授权。你可以在系统设置中开启后再试'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionTitle('输出位置'),
        _outputTile(),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '默认保存在手机"下载"目录的 FormatExport 下：文件管理器里直接可见、'
              '卸载应用也不会丢。也可以改成"应用专属目录"（无需权限、卸载即删）'
              '或你自选的目录；自选目录不可写时会自动退回应用专属目录并在转换时提示。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _sectionTitle('自定义目录的选择方式'),
        _dirPickerCard(theme),
        const SizedBox(height: 12),
        _sectionTitle('通知'),
        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: const Text('转码通知'),
            subtitle: const Text('开启后：转码时在通知栏实时显示进度，'
                '并且切到后台 / 锁屏也不会中断。'),
            value: settings.notificationsEnabled,
            onChanged: (on) async {
              final messenger = ScaffoldMessenger.of(context);
              // Android 13+ 首次开启时申请通知权限
              if (on && Platform.isAndroid) {
                final v = int.tryParse(Platform.version.split('.').first) ?? 0;
                if (v >= 33) {
                  final s = await Permission.notification.request();
                  if (!s.isGranted) {
                    messenger.showSnackBar(const SnackBar(
                      content: Text('未授予通知权限，将无法在后台显示进度通知'),
                    ));
                  }
                }
              }
              await ref
                  .read(appSettingsProvider.notifier)
                  .setNotificationsEnabled(on);
            },
          ),
        ),
        const SizedBox(height: 12),
        _sectionTitle('性能'),
        Card(
          child: ListTile(
            leading: const Icon(Icons.speed_outlined),
            title: const Text('并行任务数'),
            subtitle: const Text('同时执行任务数；1=串行，数值越高越耗 CPU/内存，视频软编建议 1~2'),
            trailing: DropdownButton<int>(
              value: settings.concurrentTasks,
              items: [
                for (final n in const [1, 2, 3, 4])
                  DropdownMenuItem(value: n, child: Text('$n')),
              ],
              onChanged: (v) {
                if (v == null) return;
                ref
                    .read(appSettingsProvider.notifier)
                    .setConcurrentTasks(v);
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        _sectionTitle('读取文件方式'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_open_outlined),
                  title: const Text('系统文件选择器'),
                  subtitle: const Text('用系统界面选择文件，无需任何权限，隐私最好'),
                  trailing: settings.pickerMode == 'saf'
                      ? Icon(Icons.check_circle,
                          color: theme.colorScheme.primary)
                      : const Icon(Icons.radio_button_unchecked),
                  onTap: () {
                    ref
                        .read(appSettingsProvider.notifier)
                        .setPickerMode('saf');
                    _refreshPermission();
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.admin_panel_settings_outlined),
                  title: const Text('文件管理权限'),
                  subtitle: const Text('Android 11+ 需开启"所有文件访问"，可浏览整台设备'),
                  trailing: settings.pickerMode == 'manage'
                      ? Icon(Icons.check_circle,
                          color: theme.colorScheme.primary)
                      : const Icon(Icons.radio_button_unchecked),
                  onTap: () {
                    ref
                        .read(appSettingsProvider.notifier)
                        .setPickerMode('manage');
                    _refreshPermission();
                  },
                ),
              ],
            ),
          ),
        ),
        if (settings.pickerMode == 'manage') ...[
          const SizedBox(height: 8),
          _permissionCard(),
        ],
        const SizedBox(height: 16),
        _sectionTitle('关于'),
        Card(
          child: ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: const Text('开源许可与致谢'),
            subtitle: const Text('本项目使用到的开源库与算法参考'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showAboutLicense,
          ),
        ),
      ],
    );
  }

  /// 弹窗展示：本项目许可证 + 使用的开源库 + 脱壳算法参考。
  void _showAboutLicense() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开源许可与致谢'),
        content: SingleChildScrollView(
          child: const Text('''本项目以 GPL-3.0 开源（仓库见 README）。

使用的开源组件：
· Flutter / Dart
· FFmpeg（内置 full-gpl 版，含 x264/x265 等）
· ffmpeg_kit_flutter_new（FFmpegKit 活跃维护 fork）
· flutter_riverpod / file_picker / share_plus
· sqflite / path_provider / permission_handler
· flutter_foreground_task（后台转码保活）

脱壳算法参考（均 MIT）：
· taurusxin/ncmdump（网易云 .ncm）
· LingBrian/ncm2mp3-js（QQ 音乐 .qmc/.mflac）
· onavcn/kugou-audio-unlock（酷狗 .kgm/.kgma/.vpr）

说明：音乐脱壳仅建议用于本人拥有合法使用权的本地文件。'''),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
    );
  }

  Widget _outputTile() {
    final settings = ref.watch(appSettingsProvider);
    final target = settings.outputTarget;
    final isDefault = target == AppSettings.targetDefault;
    final isApp = target == AppSettings.targetApp;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.secondaryContainer,
          child: const Icon(Icons.folder_outlined, size: 20),
        ),
        title: const Text('输出位置'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isDefault
                ? '默认目录（Download/FormatExport）'
                : isApp
                    ? '应用专属目录'
                    : '自定义目录'),
            if (isDefault)
              FutureBuilder<String>(
                future: FileStore.publicDirText(MediaKind.video),
                builder: (_, snap) => Text(
                  snap.data ??
                      'Download/${FileStore.publicDirName}',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else if (isApp)
              FutureBuilder<String>(
                future: FileStore.appOutputDirText(),
                builder: (_, snap) => Text(
                  snap.data ?? '',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              Text(
                target,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        trailing: TextButton(
          onPressed: () => _chooseOutput(),
          child: const Text('更改'),
        ),
      ),
    );
  }

  /// "自定义输出目录"用哪种方式挑选：系统 SAF / 内置文件浏览器。
  Widget _dirPickerCard(ThemeData theme) {
    final settings = ref.watch(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_special_outlined),
              title: const Text('系统目录选择器'),
              subtitle: const Text('用系统界面挑选目录，无需任何权限（推荐）'),
              trailing: settings.dirPickerMode == 'saf'
                  ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
                  : const Icon(Icons.radio_button_unchecked),
              onTap: () => notifier.setDirPickerMode('saf'),
            ),
            const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('内置文件浏览器'),
              subtitle: const Text(
                  '可进入 Android/data 等系统选择器打不开的目录（需"文件管理权限"）'),
              trailing: settings.dirPickerMode == 'manage'
                  ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
                  : const Icon(Icons.radio_button_unchecked),
              onTap: () => notifier.setDirPickerMode('manage'),
            ),
          ],
        ),
      ),
    );
  }

  /// 底部弹层选择输出位置：默认目录 / 应用专属目录 / 自定义目录。
  Future<void> _chooseOutput() async {
    final notifier = ref.read(appSettingsProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final settings = ref.read(appSettingsProvider);
    final current = settings.outputTarget;
    final useBuiltinPicker = settings.dirPickerMode == 'manage';
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('输出位置'),
              subtitle: Text('选择转换完成的文件保存到哪里'),
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('默认目录（推荐）'),
              subtitle: const Text('手机"下载"目录的 FormatExport 下，文件管理器可见'),
              trailing: current == AppSettings.targetDefault
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.of(ctx).pop('default'),
            ),
            ListTile(
              leading: const Icon(Icons.smartphone),
              title: const Text('应用专属目录'),
              subtitle: const Text('无需权限，卸载应用时会被删除'),
              trailing: current == AppSettings.targetApp
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.of(ctx).pop('app'),
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('选择自定义目录…'),
              subtitle: Text(useBuiltinPicker
                  ? '用内置文件浏览器挑选（需"文件管理权限"）'
                  : '用系统目录选择器挑选保存位置'),
              onTap: () => Navigator.of(ctx).pop('pick'),
            ),
          ],
        ),
      ),
    );

    if (action == null) return;
    if (action == 'default') {
      await notifier.setOutput(MediaKind.video, AppSettings.targetDefault);
      return;
    }
    if (action == 'app') {
      await notifier.setOutput(MediaKind.video, AppSettings.targetApp);
      return;
    }
    await _pickCustomDir(notifier, messenger, useBuiltinPicker);
  }

  /// 按"自定义目录的选择方式"打开内置文件浏览器或系统 SAF 选择器。
  Future<void> _pickCustomDir(
    AppSettingsNotifier notifier,
    ScaffoldMessengerState messenger,
    bool useBuiltinPicker,
  ) async {
    if (useBuiltinPicker) {
      if (!await ManagePermission.ensureGranted()) {
        messenger.showSnackBar(const SnackBar(
          content: Text('需要"所有文件访问"权限才能浏览整台设备；'
              '也可以把选择方式改成"系统目录选择器"'),
        ));
        return;
      }
      if (!mounted) return;
      final picked = await Navigator.of(context).push<List<String>>(
        MaterialPageRoute(
          builder: (_) => FileBrowserPage(
            extensions: const [],
            pickDirectory: true,
            initialPath: '/storage/emulated/0',
            title: '选择输出目录',
          ),
        ),
      );
      if (picked == null || picked.isEmpty) return;
      final root = picked.first;
      await notifier.setOutput(MediaKind.video, root);
      messenger.showSnackBar(SnackBar(
        content: Text('已设置输出目录：$root'),
      ));
      return;
    }
    // 系统目录选择器（原生 SAF）
    final uri = await StorageAccess.pickDirectory();
    if (uri == null) return; // 用户取消
    await notifier.setOutput(MediaKind.video, uri);
    messenger.showSnackBar(const SnackBar(content: Text('已设置输出目录')));
  }

  Widget _permissionCard() {
    final theme = Theme.of(context);
    final granted = _manageStatus?.isGranted ?? false;
    final title = granted ? '文件管理权限已开启' : '文件管理权限未开启';
    final body = granted
        ? '已开启：可以浏览整台设备的文件。'
        : (_isAndroid11Plus
            ? 'Android 11+：需要到系统设置里开启"所有文件访问"，才能用文件管理权限读取文件。'
            : 'Android 10 及以下：需要授予存储权限后才能浏览文件。');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          // 纯纵向布局：文字以整行宽度自然折行，任何字体大小都不会竖排
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  granted
                      ? Icons.verified_user_outlined
                      : Icons.lock_outline,
                  color: granted
                      ? const Color(0xFF2E7D32)
                      : theme.colorScheme.error,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(body, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            if (!granted)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonal(
                  onPressed: _grantManage,
                  child: const Text('去授权'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
