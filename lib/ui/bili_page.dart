import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../formats_data.dart';
import '../models.dart';
import '../services/bili_cache.dart';
import '../services/file_store.dart';
import '../services/manage_permission.dart';
import '../services/storage_access.dart';
import '../state/app_settings.dart';
import '../state/task_queue.dart';
import 'file_browser_page.dart';

/// B站缓存转视频：选缓存目录 → 解析出「视频流 + 音频流」→ 合并成普通 MP4 入队。
///
/// B站客户端把一集视频拆成 video.m4s（画面）与 audio.m4s（声音）两个文件，
/// 普通播放器打不开；本页把它们无损合并成一个 MP4（不重新编码，几秒完成）。
class BiliPage extends ConsumerStatefulWidget {
  const BiliPage({super.key});

  @override
  ConsumerState<BiliPage> createState() => _BiliPageState();
}

class _BiliPageState extends ConsumerState<BiliPage> {
  String? _rootPath;
  List<BiliCacheItem> _items = [];

  /// 已勾选的条目（key = 条目目录，保证唯一）。
  final Set<String> _selected = {};

  bool _scanning = false;

  /// SAF 副本镜像进行中（Android 13+ fallback，整树拷贝耗时不定）。
  bool _importing = false;
  bool _submitting = false;
  bool _reencode = false;
  String? _error;

  /// 手机上探测到的默认缓存目录（用于"直接读取"快捷按钮）。
  String? _defaultRoot;

  @override
  void initState() {
    super.initState();
    _detectDefaultRoot();
  }

  /// 探测 B站默认缓存目录是否存在（不存在就只提供手动选择）。
  Future<void> _detectDefaultRoot() async {
    if (!Platform.isAndroid) return;
    for (final path in BiliCache.commonRoots) {
      try {
        if (await Directory(path).exists()) {
          if (!mounted) return;
          setState(() => _defaultRoot = path);
          return;
        }
      } catch (_) {
        // 没有权限访问 Android/data：忽略，走手动选择
      }
    }
  }

  /// B站缓存位于 Android/data 下，系统文件选择器（SAF）看不到 →
  /// 必须用"文件管理权限" + 内置文件浏览器来选目录。
  Future<void> _pickDirectory() async {
    final messenger = ScaffoldMessenger.of(context);
    final granted = await ManagePermission.ensureGranted();
    if (!granted) {
      messenger.showSnackBar(const SnackBar(
        content: Text('需要"文件管理权限（所有文件访问）"才能读取 Android/data 下的缓存'
            '。请在系统弹窗或设置页中开启后重试。'),
      ));
      return;
    }
    if (!mounted) return;
    final picked = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => FileBrowserPage(
          extensions: const [],
          pickDirectory: true,
          initialPath: _rootPath ?? _defaultRoot,
          title: '选择 B站缓存目录',
        ),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    await _scan(picked.first);
  }

  /// Android 13+ 的系统限制：其他应用的 Android/data 直读被彻底封死
  ///（"所有文件访问"也读不了，SAF 也进不去那个目录）。
  /// fallback：用户用系统文件管理器把缓存目录复制到普通位置（如"下载"），
  /// 这里选副本目录 → 原生整树镜像进工作区 → 用现有扫描逻辑跑镜像。
  Future<void> _importViaSaf() async {
    final messenger = ScaffoldMessenger.of(context);
    final picked = await StorageAccess.pickDirectory();
    if (picked == null || !mounted) return;
    setState(() {
      _importing = true;
      _error = null;
    });
    final work = await FileStore.workDir(MediaKind.video);
    final r = await StorageAccess.importTree(
      treeUri: picked,
      destDir: '${work.path}${Platform.pathSeparator}BiliImport',
    );
    if (!mounted) return;
    if (r == null) {
      setState(() => _importing = false);
      messenger.showSnackBar(const SnackBar(
        content: Text('导入失败：无法读取所选目录，请确认选的是复制出来的缓存副本目录'),
      ));
      return;
    }
    if (r.files == 0) {
      setState(() => _importing = false);
      messenger.showSnackBar(const SnackBar(
        content: Text('所选目录是空的。请确认选的是复制出来的 download 目录'
            '（里面应有以数字命名的子文件夹和 entry.json）'),
      ));
      return;
    }
    // _scan 内部会接管 _scanning/_importing 状态并渲染列表
    setState(() => _importing = false);
    await _scan(r.mirrorDir);
  }

  /// 扫描指定目录；解析失败给出提示而不是崩溃。
  Future<void> _scan(String path) async {
    setState(() {
      _scanning = true;
      _error = null;
      _items = const [];
      _selected.clear();
      _rootPath = path;
    });
    try {
      final items = await BiliCache.scan(path);
      if (!mounted) return;
      setState(() {
        _items = items;
        _selected.addAll(items.map((e) => e.sourceDir));
        _scanning = false;
      });
      if (items.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('这个目录里没有找到 B站缓存（需要包含 entry.json 与 '
              'video.m4s / audio.m4s）。可以选上一级目录再试。'),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = '读取失败：${e.toString().replaceFirst('Exception: ', '')}\n'
            '请确认已开启"所有文件访问"权限，且该目录确实是 B站缓存目录。';
      });
    }
  }

  /// 把勾选的缓存视频加入统一任务队列（走和普通转换一样的后台队列）。
  Future<void> _enqueue() async {
    final picked =
        _items.where((e) => _selected.contains(e.sourceDir)).toList();
    if (picked.isEmpty || _submitting) return;
    setState(() => _submitting = true);

    final messenger = ScaffoldMessenger.of(context);
    final target = ref.read(appSettingsProvider).outputTarget;
    final now = DateTime.now();
    final reencode = _reencode;
    final preset =
        presetById(MediaKind.video, 'mp4_h264') ?? presetsFor(MediaKind.video).first;
    final settings = ConvertSettings({
      for (final f in preset.fields) f.key: f.initialValue,
    });

    final tasks = <ConvertTask>[];
    String? warning;
    // 同批任务的批内去重：番剧多集同名时路径一次性生成，防止撞车
    final claimed = <String>{};
    for (final item in picked) {
      // 纯音频缓存输出 m4a；重新编码只对“有画面”的条目有意义
      final doEncode = reencode && item.hasVideo;
      final ext = item.hasVideo ? 'mp4' : 'm4a';
      final name = BiliCache.safeFileName(item.title);
      final plan = await FileStore.plan(
        MediaKind.video,
        '$name.$ext',
        ext,
        target: target,
        claimed: claimed,
      );
      warning ??= plan.warning;
      tasks.add(ConvertTask(
        id: TaskQueue.newId(),
        kind: MediaKind.video,
        inputPath: item.videoPath,
        inputName: '$name.$ext',
        presetId: doEncode ? preset.id : BiliCache.kCopyPresetId,
        presetName: doEncode ? 'MP4（重新编码）' : 'MP4（缓存合并）',
        settings: doEncode ? settings : ConvertSettings.empty,
        outputPath: plan.path,
        createdAt: now,
        mergeAudioPath: item.audioPath,
        safTreeUri: plan.safTreeUri,
        mediaStoreDir: plan.mediaStoreDir,
        inputDurationSeconds: item.durationSeconds,
      ));
    }

    ref.read(taskQueueProvider.notifier).enqueue(tasks);
    if (!mounted) return;
    setState(() => _submitting = false);
    final msg = warning == null
        ? '已把 ${tasks.length} 个缓存视频加入队列'
        : '$warning；已把 ${tasks.length} 个缓存视频加入队列';
    messenger.showSnackBar(SnackBar(content: Text(msg)));
    Navigator.of(context).pop(tasks.length);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('B站缓存转视频'),
        actions: [
          if (_rootPath != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '重新扫描',
              onPressed: _scanning ? null : () => _scan(_rootPath!),
            ),
        ],
      ),
      body: _body(theme),
      bottomNavigationBar: _items.isEmpty ? null : _bottomBar(theme),
    );
  }

  Widget _body(ThemeData theme) {
    if (_importing) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('正在复制缓存副本到工作区…\n取决于缓存大小，可能需要一会儿',
                textAlign: TextAlign.center),
          ],
        ),
      );
    }
    if (_scanning) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('正在扫描缓存目录…'),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  color: theme.colorScheme.error, size: 40),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _pickDirectory,
                icon: const Icon(Icons.folder_open),
                label: const Text('重新选择目录'),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) return _emptyView(theme);
    return _listView(theme);
  }

  /// 还没选目录 / 目录里没有缓存时的说明页。
  Widget _emptyView(ThemeData theme) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Icon(Icons.video_library_outlined,
              size: 56, color: theme.colorScheme.primary),
          const SizedBox(height: 12),
          Text('把 B站缓存的视频合并成普通 MP4',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            'B站客户端把一集视频拆成 video.m4s（画面）和 audio.m4s（声音）两个文件，'
            '普通播放器打不开。这里把它们无损合并成一个 MP4 —— 不重新编码，画质不变，'
            '几秒钟就能完成。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (_defaultRoot != null) ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.folder_special),
                title: const Text('读取默认缓存目录'),
                subtitle: Text(_defaultRoot!,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () => _scan(_defaultRoot!),
              ),
            ),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            onPressed: _pickDirectory,
            icon: const Icon(Icons.folder_open),
            label: const Text('选择缓存目录'),
          ),
          const SizedBox(height: 16),
          // Android 13+ 系统封死其他应用 Android/data 的直读与 SAF 访问，
          // 内置浏览器这条路在那之后系统上走不通 → 提供"副本导入"
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('系统限制时的替代导入（Android 13+）',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Text(
                    '如果你的系统不允许应用读取 B站缓存目录（选目录后报读取失败'
                    '就是这种情况）：\n'
                    '1. 用系统自带"文件管理"找到并进入 '
                    'Android/data/tv.danmaku.bili/download\n'
                    '2. 把整个 download 文件夹复制到普通位置（如"下载"）\n'
                    '3. 点下面按钮，选中复制出来的那个目录',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _importViaSaf,
                    icon: const Icon(Icons.copy_all_outlined),
                    label: const Text('从缓存副本目录导入'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '缓存目录一般是：\n'
            '/storage/emulated/0/Android/data/tv.danmaku.bili/download\n'
            '（选 download 目录或它的上级都行；需要"所有文件访问"权限，'
            '下面会用应用内文件浏览器让你挑目录）',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      );

  /// 找到的缓存视频列表（默认全选，用户可取消）。
  Widget _listView(ThemeData theme) => ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              '共 ${_items.length} 个缓存视频，默认全部勾选\n${_rootPath ?? ''}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
          const Divider(height: 1),
          for (final item in _items) _itemTile(item, theme),
        ],
      );

  Widget _itemTile(BiliCacheItem item, ThemeData theme) {
    final selected = _selected.contains(item.sourceDir);
    final parts = <String>[
      item.qualityTag,
      if (item.sizeBytes > 0) formatBytes(item.sizeBytes),
      if (item.durationSeconds != null) formatClock(item.durationSeconds!),
      if (!item.hasVideo) '仅音频',
    ];
    return CheckboxListTile(
      value: selected,
      onChanged: (v) => setState(() {
        if (v == true) {
          _selected.add(item.sourceDir);
        } else {
          _selected.remove(item.sourceDir);
        }
      }),
      title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(parts.join(' · '), style: theme.textTheme.bodySmall),
          if (!item.complete)
            Text('⚠ 这集在客户端里可能还没下载完整',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
        ],
      ),
    );
  }

  /// 底部：合并方式开关 + 全选 + 加入队列。
  Widget _bottomBar(ThemeData theme) {
    var totalBytes = 0;
    for (final item in _items) {
      if (_selected.contains(item.sourceDir)) totalBytes += item.sizeBytes;
    }
    final allSelected = _selected.length == _items.length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _reencode,
              onChanged:
                  _submitting ? null : (v) => setState(() => _reencode = v),
              title: const Text('重新编码为 H.264（兼容性最好）'),
              subtitle: const Text(
                  '关闭：只做封装合并，几秒完成、画质无损（画面可能是 H.265，'
                  '个别老设备播不了）；打开：重新编码，慢但到处都能播'),
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _submitting
                      ? null
                      : () => setState(() {
                            if (allSelected) {
                              _selected.clear();
                            } else {
                              _selected
                                  .addAll(_items.map((e) => e.sourceDir));
                            }
                          }),
                  icon: Icon(allSelected ? Icons.deselect : Icons.select_all,
                      size: 18),
                  label: Text(allSelected ? '全不选' : '全选'),
                ),
                const Spacer(),
                Text('已选 ${_selected.length} 项 · ${formatBytes(totalBytes)}',
                    style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed:
                    (_selected.isEmpty || _submitting) ? null : _enqueue,
                icon: _submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.merge_type),
                label: Text(_submitting
                    ? '正在加入队列…'
                    : '合并并加入队列 (${_selected.length})'),
              ),
            ),
          ],
        ),
      ),
    );
  }

}
