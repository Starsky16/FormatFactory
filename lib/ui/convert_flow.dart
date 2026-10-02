import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models.dart';
import '../services/manage_permission.dart';
import '../services/media_probe.dart';
import '../state/app_settings.dart';
import 'convert_settings.dart';
import 'file_browser_page.dart';
import 'picked_media.dart';

/// 各类别允许选择的扩展名（系统文件选择器用来过滤）。
const List<String> kVideoExtensions = [
  'mp4', 'mkv', 'mov', 'avi', 'wmv', 'flv', 'webm', 'm4v', '3gp',
  'mpg', 'mpeg', 'mts', 'm2ts', 'ts', 'rm', 'rmvb', 'f4v', 'asf', 'vob',
];
const List<String> kAudioExtensions = [
  'mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg', 'opus', 'wma', 'amr',
  'ac3', 'ape', 'aiff', 'mka',
];

/// 音频转换允许的输入 = 音频本身 + 视频。
/// 选到视频时由 FFmpeg 只提取里面的音轨（音频预设统一带 `-vn`），
/// 因此"视频转 MP3"这类需求不需要另建入口。
const List<String> kAudioInputExtensions = [
  ...kAudioExtensions,
  ...kVideoExtensions,
];

const List<String> kImageExtensions = [
  'jpg', 'jpeg', 'png', 'bmp', 'webp', 'gif', 'tif', 'tiff', 'ico',
  'heic', 'heif', 'jfif',
];

/// 转换流程第一步：选择并预览待转换文件。
/// 用户点"选择格式并转换"后进入 ConvertSettingsPage；
/// 那边入队成功会把本次添加的任务数量 pop 回来，本页再 pop 给首页。
class ConvertFlow extends ConsumerStatefulWidget {
  const ConvertFlow({super.key, required this.kind});

  final MediaKind kind;

  @override
  ConsumerState<ConvertFlow> createState() => _ConvertFlowState();
}

class _ConvertFlowState extends ConsumerState<ConvertFlow> {
  final List<PickedMedia> _files = [];
  bool _picking = false;

  List<String> get _exts => switch (widget.kind) {
        MediaKind.video => kVideoExtensions,
        MediaKind.audio => kAudioInputExtensions,
        MediaKind.image => kImageExtensions,
      };

  /// 空列表页的提示文案（音频类额外说明"选视频只取音轨"）。
  String get _extsHint => switch (widget.kind) {
        MediaKind.audio => '支持音频（${kAudioExtensions.join(' / ')}），'
            '也支持视频（${kVideoExtensions.join(' / ')}）——'
            '选视频时只提取其中的音轨；可一次多选',
        _ => '支持 ${_exts.join(' / ')} 等格式，可一次多选',
      };

  Future<void> _pickFiles() async {
    // 按设置里的"读取文件方式"选择文件：SAF 系统选择器 / 文件管理权限浏览器
    final mode = ref.read(appSettingsProvider).pickerMode;
    if (mode == 'manage' && Platform.isAndroid) {
      await _pickWithBrowser();
      return;
    }
    await _pickWithSystemPicker();
  }

  /// 方式一：系统文件选择器（SAF），无需权限。
  Future<void> _pickWithSystemPicker() async {
    setState(() => _picking = true);
    try {
      List<PlatformFile> files;
      try {
        files = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: _exts,
        );
      } catch (_) {
        // 个别机型对自定义过滤支持不好，退化为"选任意文件"
        files = await FilePicker.pickFiles();
      }
      if (files.isEmpty) return; // 用户取消

      final fresh = <PickedMedia>[];
      for (final f in files) {
        if (f.path == null) continue; // Android 上都有本地缓存路径
        if (_files.any((e) => e.path == f.path)) continue; // 去重
        fresh.add(PickedMedia(
          path: f.path!,
          name: f.name,
          sizeBytes: f.lengthSync() ?? 0,
        ));
      }
      if (fresh.isEmpty) return;

      setState(() => _files.addAll(fresh));
      _probeAll(fresh);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开文件选择器失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 方式二：文件管理权限 + 自建文件浏览器。
  Future<void> _pickWithBrowser() async {
    setState(() => _picking = true);
    try {
      final granted = await _ensureManagePermission();
      if (!granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('需要"所有文件访问"权限才能浏览整台设备。'
                '请到设置页开启该权限后再试。'),
          ));
        }
        return;
      }
      if (!mounted) return; // 授权期间页面可能已被销毁
      final picked = await Navigator.of(context).push<List<String>>(
        MaterialPageRoute(
          builder: (_) => FileBrowserPage(extensions: _exts),
        ),
      );
      if (picked == null || picked.isEmpty || !mounted) return;

      final fresh = <PickedMedia>[];
      for (final p in picked) {
        if (_files.any((e) => e.path == p)) continue; // 去重
        final f = File(p);
        fresh.add(PickedMedia(
          path: p,
          name: p.split(Platform.pathSeparator).last,
          sizeBytes: _safeFileSize(f),
        ));
      }
      if (fresh.isEmpty) return;
      setState(() => _files.addAll(fresh));
      _probeAll(fresh);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 请求文件管理权限并返回是否已授予（Android 9/10 与 11+ 自动分流）。
  Future<bool> _ensureManagePermission() => ManagePermission.ensureGranted();

  static int _safeFileSize(File f) {
    try {
      return f.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  /// 逐个用 FFprobe 读信息（用于显示与算进度）。
  Future<void> _probeAll(List<PickedMedia> list) async {
    for (final m in list) {
      final info = await MediaProbe.probe(m.path);
      if (!mounted) return;
      setState(() {
        m.info = info;
        m.probing = false;
      });
    }
  }

  void _remove(PickedMedia m) {
    setState(() => _files.remove(m));
  }

  Future<void> _gotoSettings() async {
    final added = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => ConvertSettingsPage(
          kind: widget.kind,
          files: List.of(_files),
        ),
      ),
    );
    if (added != null && added > 0 && mounted) {
      // 入队成功，把数量带回首页，让它切换到"任务"标签
      Navigator.of(context).pop(added);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.kind.label}转换')),
      body: _files.isEmpty ? _emptyHint() : _fileList(scheme),
      bottomNavigationBar: _files.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _picking ? null : _pickFiles,
                      icon: const Icon(Icons.add),
                      label: const Text('继续添加'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _gotoSettings,
                        icon: const Icon(Icons.tune),
                        label: Text('选择格式并转换 (${_files.length})'),
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
            Icon(
              Icons.file_open_outlined,
              size: 72,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            const Text('还没有选择文件', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Text(
              _extsHint,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _picking ? null : _pickFiles,
              icon: const Icon(Icons.folder_open),
              label: const Text('选择文件'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fileList(ColorScheme scheme) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: _files.length,
      itemBuilder: (context, i) {
        final m = _files[i];
        final subtitle = StringBuffer();
        subtitle
          ..write(formatBytes(m.sizeBytes))
          ..write(' · ');
        if (m.probing) {
          subtitle.write('读取信息中…');
        } else if (m.info == null) {
          subtitle.write('⚠ 无法识别，可能是不支持的格式');
        } else {
          subtitle.write(m.info!.line);
        }
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: scheme.secondaryContainer,
            child: Icon(_kindIcon(widget.kind), size: 20),
          ),
          title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(subtitle.toString(), maxLines: 2),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            tooltip: '移除',
            onPressed: () => _remove(m),
          ),
        );
      },
    );
  }
}

IconData _kindIcon(MediaKind kind) => switch (kind) {
      MediaKind.video => Icons.videocam_outlined,
      MediaKind.audio => Icons.music_note,
      MediaKind.image => Icons.image_outlined,
    };

