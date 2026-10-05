import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models.dart';
import '../services/compress_calc.dart';
import '../services/ffmpeg_engine.dart';
import '../services/file_store.dart';
import '../services/manage_permission.dart';
import '../services/media_probe.dart';
import '../state/app_settings.dart';
import '../state/task_queue.dart';
import 'convert_flow.dart';
import 'file_browser_page.dart';
import 'picked_media.dart';

/// 视频压缩：按目标体积两遍编码压成 MP4。
/// 多选时目标体积为"每文件"统一值；可选裁剪与分段（分段入队即展开成多任务）。
class CompressionPage extends ConsumerStatefulWidget {
  const CompressionPage({super.key});

  @override
  ConsumerState<CompressionPage> createState() => _CompressionPageState();
}

class _CompressionPageState extends ConsumerState<CompressionPage> {
  final List<PickedMedia> _files = [];
  final _targetCtrl = TextEditingController();
  final _trimStartCtrl = TextEditingController();
  final _trimEndCtrl = TextEditingController();
  final _segmentCtrl = TextEditingController();
  String _resolutionCap = '原始尺寸';
  String _fpsCap = '';
  bool _picking = false;
  bool _submitting = false;

  static const _resolutionOptions = ['原始尺寸', '1080p', '720p', '480p'];
  static const _fpsOptions = {'': '不限', '30': '30 fps', '24': '24 fps'};

  @override
  void dispose() {
    for (final c in [
      _targetCtrl,
      _trimStartCtrl,
      _trimEndCtrl,
      _segmentCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------- 选文件（与转换页同款双模式） ----------

  Future<void> _pickFiles() async {
    final mode = ref.read(appSettingsProvider).pickerMode;
    if (mode == 'manage' && Platform.isAndroid) {
      await _pickWithBrowser();
      return;
    }
    await _pickWithSystemPicker();
  }

  Future<void> _pickWithSystemPicker() async {
    setState(() => _picking = true);
    try {
      List<PlatformFile> files;
      try {
        files = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: kVideoExtensions,
        );
      } catch (_) {
        files = await FilePicker.pickFiles();
      }
      await _addPicked([
        for (final f in files)
          if (f.path != null)
            PickedMedia(path: f.path!, name: f.name, sizeBytes: f.lengthSync() ?? 0),
      ]);
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

  Future<void> _pickWithBrowser() async {
    setState(() => _picking = true);
    try {
      final granted = await ManagePermission.ensureGranted();
      if (!granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('需要"所有文件访问"权限才能浏览整台设备。'
                '请到设置页开启该权限后再试。'),
          ));
        }
        return;
      }
      if (!mounted) return;
      final picked = await Navigator.of(context).push<List<String>>(
        MaterialPageRoute(
          builder: (_) => FileBrowserPage(extensions: kVideoExtensions),
        ),
      );
      if (picked == null || picked.isEmpty || !mounted) return;
      await _addPicked([
        for (final path in picked)
          PickedMedia(
            path: path,
            name: path.split(Platform.pathSeparator).last,
            sizeBytes: _safeFileSize(File(path)),
          ),
      ]);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _addPicked(List<PickedMedia> fresh) async {
    final add = [
      for (final f in fresh)
        if (!_files.any((e) => e.path == f.path)) f,
    ];
    if (add.isEmpty) return;
    setState(() => _files.addAll(add));
    _hintBigFiles(add);
    // 默认目标体积：第一个文件体积的 40%（多选时按"每文件"统一值）
    if (_targetCtrl.text.trim().isEmpty) {
      final suggest = defaultTargetMB(_files.first.sizeBytes);
      if (suggest != null) _targetCtrl.text = '$suggest';
    }
    for (final m in add) {
      final info = await MediaProbe.probe(m.path);
      if (!mounted) return;
      setState(() {
        m.info = info;
        m.probing = false;
      });
    }
  }

  /// 大文件提示：系统选择器（SAF）会先把文件复制进应用缓存再给路径，
  /// 4GB 级视频要等数秒到数十秒；设备浏览模式直接读原路径，零复制。
  void _hintBigFiles(List<PickedMedia> fresh) {
    const bigThreshold = 1024 * 1024 * 1024;
    if (!fresh.any((f) => f.sizeBytes > bigThreshold)) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('检测到大文件：系统文件选择器会先把文件复制到应用缓存，'
          '首次选取可能较慢。建议到「设置 → 文件选择方式」切换为设备浏览，'
          '直接读取原文件，无需复制。'),
      duration: Duration(seconds: 5),
    ));
  }

  static int _safeFileSize(File f) {
    try {
      return f.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  // ---------- 入队 ----------

  Future<void> _submit() async {
    if (_files.isEmpty || _submitting) return;
    final targetMB = int.tryParse(_targetCtrl.text.trim());
    if (targetMB == null || targetMB <= 0) {
      _toast('请填写目标体积（MB）');
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _submitting = true);

    // 入队前校验：每个文件按（裁剪后）时长算码率，目标过小直接拦下
    for (final f in _files) {
      final dur = effectiveDuration(
        sourceDuration: f.info?.durationSeconds ?? 0,
        trimStart: _trimStartCtrl.text,
        trimEnd: _trimEndCtrl.text,
      );
      if (calcBitrates(
            targetBytes: targetMB * 1024 * 1024,
            durationSeconds: dur,
          ) ==
          null) {
        if (mounted) setState(() => _submitting = false);
        messenger.showSnackBar(SnackBar(content: Text(
          '「${f.name}」按目标体积算出的画面码率太低（目标过小或时长过长），'
          '建议调大目标体积或降低分辨率/帧率上限。',
        )));
        return;
      }
    }

    final tasks = <ConvertTask>[];
    final now = DateTime.now();
    final target = ref.read(appSettingsProvider).targetOf(MediaKind.video);
    final claimed = <String>{};
    String? warning;
    for (final f in _files) {
      final plan = await FileStore.plan(
          MediaKind.video, f.name, 'mp4',
          target: target, claimed: claimed);
      warning ??= plan.warning;
      final base = ConvertTask(
        id: TaskQueue.newId(),
        kind: MediaKind.video,
        inputPath: f.path,
        inputName: f.name,
        presetId: FfmpegEngine.compressPresetId,
        presetName: '视频压缩',
        settings: ConvertSettings({
          SettingKey.targetVolumeMB: '$targetMB',
          SettingKey.resolutionCap: _resolutionCap,
          if (_fpsCap.isNotEmpty) SettingKey.fpsCap: _fpsCap,
          if (_trimStartCtrl.text.trim().isNotEmpty)
            SettingKey.trimStart: _trimStartCtrl.text.trim(),
          if (_trimEndCtrl.text.trim().isNotEmpty)
            SettingKey.trimEnd: _trimEndCtrl.text.trim(),
          if (_segmentCtrl.text.trim().isNotEmpty)
            SettingKey.segmentMinutes: _segmentCtrl.text.trim(),
        }),
        outputPath: plan.path,
        createdAt: now,
        safTreeUri: plan.safTreeUri,
        mediaStoreDir: plan.mediaStoreDir,
        inputDurationSeconds: f.info?.durationSeconds,
        inputBytes: f.sizeBytes,
      );
      // 填了分段：入队即展开成 N 个任务（每段独立裁剪边界与目标体积）
      tasks.addAll(expandSegments(base));
    }
    if (!mounted) return;
    setState(() => _submitting = false);
    if (warning != null) {
      messenger.showSnackBar(SnackBar(content: Text(warning)));
    }
    ref.read(taskQueueProvider.notifier).enqueue(tasks);
    Navigator.of(context).pop(tasks.length);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- 界面 ----------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('视频压缩')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '按目标体积压缩，输出 MP4（H.264 + AAC），压完可直接发微信。'
            '默认硬件加速编码（快 5~10 倍，体积略有偏差），不支持或失败时'
            '自动回退两遍软编精确命中目标体积。',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _picking ? null : _pickFiles,
            icon: const Icon(Icons.add),
            label: Text(_files.isEmpty ? '选择视频' : '继续添加'),
          ),
          const SizedBox(height: 8),
          for (final f in _files) _fileTile(f),
          if (_files.isNotEmpty) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _targetCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '目标体积（每文件）',
                suffixText: 'MB',
                hintText: '压到多少 MB',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _resolutionCap,
              decoration: const InputDecoration(
                labelText: '分辨率上限',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final o in _resolutionOptions)
                  DropdownMenuItem(value: o, child: Text(o)),
              ],
              onChanged: (v) => setState(() => _resolutionCap = v ?? '原始尺寸'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _fpsCap,
              decoration: const InputDecoration(
                labelText: '帧率上限',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final e in _fpsOptions.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _fpsCap = v ?? ''),
            ),
            const SizedBox(height: 4),
            _advanced(theme),
          ],
        ],
      ),
      bottomNavigationBar: _files.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: _submitting ? null : _submit,
                  icon: const Icon(Icons.compress),
                  label: Text('开始压缩 ${_files.length} 个文件'),
                ),
              ),
            ),
    );
  }

  Widget _fileTile(PickedMedia m) {
    final subtitle = StringBuffer()..write(formatBytes(m.sizeBytes))..write(' · ');
    if (m.probing) {
      subtitle.write('读取信息中…');
    } else if (m.info == null) {
      subtitle.write('⚠ 无法识别');
    } else {
      subtitle.write(m.info!.durationText);
    }
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.videocam_outlined),
      title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle.toString(), maxLines: 1),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        tooltip: '移除',
        onPressed: () => setState(() => _files.remove(m)),
      ),
    );
  }

  /// 折叠区：裁剪起止 + 分段分钟。
  Widget _advanced(ThemeData theme) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('裁剪 / 分段（可选）'),
      subtitle: Text('不填 = 整个视频、不分段',
          style: theme.textTheme.bodySmall),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      children: [
        TextField(
          controller: _trimStartCtrl,
          decoration: const InputDecoration(
            labelText: '开始时间',
            hintText: '如 1:23:45 / 12:34 / 90',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _trimEndCtrl,
          decoration: const InputDecoration(
            labelText: '结束时间',
            hintText: '留空 = 到结尾',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _segmentCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: '分段：每段时长（分钟）',
            hintText: '留空 = 不分段',
            helperText: '分段会自动拆成多个任务，每段均分目标体积',
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }
}
