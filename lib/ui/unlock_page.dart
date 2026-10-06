import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models.dart';
import '../services/file_store.dart';
import '../services/manage_permission.dart';
import '../services/unlock_api.dart';
import '../state/app_settings.dart';
import '../state/task_queue.dart';
import 'file_browser_page.dart';

/// 按源扩展名显示脱壳名称。
String unlockLabelFor(String ext) => switch (ext) {
      'ncm' => 'NCM 脱壳',
      _ when kQmcExtensions.contains(ext) => 'QMC 脱壳',
      'vpr' => 'VPR 脱壳',
      _ when kKgmExtensions.contains(ext) => 'KGM 脱壳',
      _ when kKwmExtensions.contains(ext) => 'KWM 脱壳',
      _ => '音乐脱壳',
    };

/// 音乐脱壳（选择页）。
/// 勾选 .ncm 后点"加入任务队列"，真正的解密由 TaskQueue 在
/// "转换任务"页执行并同步通知栏 —— 与普通转换完全一致。
class UnlockPage extends ConsumerStatefulWidget {
  const UnlockPage({super.key});

  @override
  ConsumerState<UnlockPage> createState() => _UnlockPageState();
}

class _Selected {
  _Selected({required this.path, required this.name, required this.size});
  final String path;
  final String name;
  final int size;
}

class _UnlockPageState extends ConsumerState<UnlockPage> {
  final List<_Selected> _items = [];
  bool _submitting = false;

  Future<void> _pick() async {
    // 与转换流程一致：按设置里的"读取文件方式"选择
    final mode = ref.read(appSettingsProvider).pickerMode;
    if (mode == 'manage' && Platform.isAndroid) {
      await _pickWithBrowser();
      return;
    }
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: kAllUnlockExtensions,
      );
      if (files.isEmpty) return;
      _addPaths([for (final f in files) if (f.path != null) f.path!]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择文件失败：$e')),
        );
      }
    }
  }

  /// 文件管理权限模式：用自建文件浏览器选取。
  Future<void> _pickWithBrowser() async {
    final messenger = ScaffoldMessenger.of(context);
    final granted = await ManagePermission.ensureGranted();
    if (!granted) {
      messenger.showSnackBar(const SnackBar(
        content: Text('需要"文件管理权限"才能浏览文件。请在系统弹窗中开启后重试。'),
      ));
      return;
    }
    if (!mounted) return;
    final picked = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => FileBrowserPage(extensions: kAllUnlockExtensions),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    _addPaths(picked);
  }

  void _addPaths(List<String> paths) {
    final fresh = <_Selected>[];
    for (final p in paths) {
      if (_items.any((e) => e.path == p)) continue;
      final f = File(p);
      fresh.add(_Selected(
        path: p,
        name: p.split(Platform.pathSeparator).last,
        size: _safeSize(f),
      ));
    }
    if (fresh.isEmpty) return;
    setState(() => _items.addAll(fresh));
  }

  static int _safeSize(File f) {
    try {
      return f.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  /// 把所有待脱壳文件作为一个任务加入统一队列，返回数量后让首页切到"任务"页。
  Future<void> _enqueueAll() async {
    if (_submitting || _items.isEmpty) return;
    setState(() => _submitting = true);
    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now();
    final target = ref.read(appSettingsProvider).targetOf(MediaKind.audio);
    final out = await FileStore.resolve(MediaKind.audio, target);
    final destDir = out.dir;

    final tasks = <ConvertTask>[];
    for (final e in _items) {
      final ext = e.path.split('.').last.toLowerCase();
      tasks.add(ConvertTask(
        id: TaskQueue.newId(),
        kind: MediaKind.audio,
        inputPath: e.path,
        inputName: e.name,
        presetId: 'unlock_$ext', // 历史重试时据此识别为脱壳任务
        presetName: unlockLabelFor(ext),
        settings: ConvertSettings.empty,
        // 脱壳输出扩展名由原生端判断：这里传"输出目录"，成功后队列会更新为真实文件
        outputPath: destDir.path,
        createdAt: now,
        unlockFormat: ext,
        safTreeUri: out.safTreeUri,
        mediaStoreDir: out.mediaStoreDir,
      ));
    }
    ref.read(taskQueueProvider.notifier).enqueue(tasks);
    if (!mounted) return;
    final msg = out.warning == null
        ? '已将 ${tasks.length} 个脱壳任务加入队列'
        : '${out.warning}；已将 ${tasks.length} 个脱壳任务加入队列';
    messenger.showSnackBar(SnackBar(content: Text(msg)));
    Navigator.of(context).pop(tasks.length);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('音乐脱壳')),
      body: _items.isEmpty ? _emptyHint() : _itemList(scheme),
      bottomNavigationBar: _items.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _submitting ? null : _pick,
                      icon: const Icon(Icons.add),
                      label: const Text('继续添加'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _submitting ? null : _enqueueAll,
                        icon: const Icon(Icons.playlist_add),
                        label:
                            Text('加入任务队列 (${_items.length})'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _emptyHint() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_open_outlined,
                size: 72, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            const Text('选择加密音乐文件'),
            const SizedBox(height: 8),
            Text(
              '支持网易云 .ncm、QQ .qmc/.mflac/.mgg、酷狗 .kgm/.kgma/.vpr、酷我 .kwm（v1）\n还原为原始 flac / mp3 / ogg 等（不转码）\n解密进度会显示在"任务"页',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.folder_open),
              label: const Text('选择文件'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemList(ColorScheme scheme) {
    return ListView.builder(
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final e = _items[i];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: scheme.secondaryContainer,
            child: const Icon(Icons.lock_open_outlined, size: 20),
          ),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('将解密为原始格式 · ${formatBytes(e.size)}',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            onPressed:
                _submitting ? null : () => setState(() => _items.removeAt(i)),
          ),
        );
      },
    );
  }
}

