import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../models.dart';
import '../services/compress_calc.dart';
import '../services/file_store.dart';
import '../services/ffmpeg_engine.dart';
import '../state/app_settings.dart';
import '../state/history_notifier.dart';
import '../state/task_queue.dart';

/// 转码历史页：展示历史记录，支持 再次转换 / 分享 / 删除 / 清空。
class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider);
    return history.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('读取历史失败：$e')),
      data: (rows) {
        if (rows.isEmpty) return const _EmptyHistory();
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 8),
          itemCount: rows.length,
          itemBuilder: (context, i) => _HistoryTile(entry: rows[i]),
        );
      },
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history,
                size: 72, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            const Text('暂无历史记录'),
            const SizedBox(height: 8),
            Text(
              '转换过的任务会按时间保存在这里，可一键重试',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryTile extends ConsumerWidget {
  const _HistoryTile({required this.entry});

  final HistoryEntry entry;

  static String _shortTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.month}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = entry.status;
    final statusColor = switch (status) {
      TaskStatus.succeeded => const Color(0xFF2E7D32),
      TaskStatus.failed => theme.colorScheme.error,
      TaskStatus.canceled => theme.colorScheme.outline,
      TaskStatus.running || TaskStatus.queued => theme.colorScheme.primary,
    };

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: statusColor.withValues(alpha: 0.14),
          child: Icon(
            switch (entry.kind) {
              MediaKind.video => Icons.videocam_outlined,
              MediaKind.audio => Icons.music_note,
              MediaKind.image => Icons.image_outlined,
            },
            color: statusColor,
            size: 20,
          ),
        ),
        title: Text(entry.inputName,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              '${entry.presetName} · ${entry.settings.summary}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (_effectLine.isNotEmpty)
              Text(
                _effectLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            Text(
              '${status.label} · ${_shortTime(entry.finishedAt)}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) => _onAction(context, ref, v),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'retry', child: Text('再次转换')),
            PopupMenuItem(value: 'share', child: Text('分享输出文件')),
            PopupMenuItem(value: 'delete', child: Text('删除这条记录')),
          ],
        ),
      ),
    );
  }

  /// 压缩任务且成功时显示体积对比；其余情况为空（不显示）。
  String get _effectLine {
    if (entry.status != TaskStatus.succeeded ||
        entry.presetId != FfmpegEngine.compressPresetId ||
        entry.inputBytes == null) {
      return '';
    }
    final f = File(entry.outputPath);
    final outBytes = f.existsSync() ? f.lengthSync() : 0;
    return compressEffectText(entry.inputBytes!, outBytes);
  }

  Future<void> _onAction(
      BuildContext context, WidgetRef ref, String action) async {
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(historyProvider.notifier);

    if (action == 'delete') {
      await notifier.remove(entry.taskId);
      return;
    }
    if (action == 'share') {
      if (!File(entry.outputPath).existsSync()) {
        messenger.showSnackBar(const SnackBar(content: Text('输出文件已不存在')));
        return;
      }
      try {
        await SharePlus.instance.share(
          ShareParams(files: [XFile(entry.outputPath)]),
        );
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('分享失败：$e')));
      }
      return;
    }
    if (action == 'retry') {
      if (!File(entry.inputPath).existsSync()) {
        messenger
            .showSnackBar(const SnackBar(content: Text('源文件已不存在，无法重试')));
        return;
      }
      // 脱壳任务（presetId 形如 unlock_ncm）重试：
      // 输出目录按"当前设置"重新解析——默认输出走 MediaStore 导入，
      // 产物是先落在内部工作区再搬运出去的，沿用历史里的旧目录会看不到文件。
      final isUnlock = entry.presetId.startsWith('unlock_');
      if (isUnlock) {
        final out = await FileStore.resolve(
          entry.kind,
          ref.read(appSettingsProvider).targetOf(entry.kind),
        );
        final task = ConvertTask(
          id: TaskQueue.newId(),
          kind: entry.kind,
          inputPath: entry.inputPath,
          inputName: entry.inputName,
          presetId: entry.presetId,
          presetName: entry.presetName,
          settings: entry.settings,
          outputPath: out.dir.path,
          createdAt: DateTime.now(),
          unlockFormat: entry.presetId.substring('unlock_'.length),
          safTreeUri: out.safTreeUri,
          mediaStoreDir: out.mediaStoreDir,
        );
        ref.read(taskQueueProvider.notifier).enqueue([task]);
        final unlockMsg = out.warning == null
            ? '已加入任务队列'
            : '${out.warning}；已加入任务队列';
        messenger.showSnackBar(SnackBar(content: Text(unlockMsg)));
        return;
      }
      final dot = entry.outputPath.lastIndexOf('.');
      final ext =
          dot >= 0 ? entry.outputPath.substring(dot + 1) : 'mp4';
      final target =
          ref.read(appSettingsProvider).targetOf(entry.kind);
      final plan = await FileStore.plan(
        entry.kind,
        entry.inputName,
        ext,
        target: target,
      );
      final task = ConvertTask(
        id: TaskQueue.newId(),
        kind: entry.kind,
        inputPath: entry.inputPath,
        inputName: entry.inputName,
        presetId: entry.presetId,
        presetName: entry.presetName,
        settings: entry.settings,
        outputPath: plan.path,
        createdAt: DateTime.now(),
        safTreeUri: plan.safTreeUri,
        mediaStoreDir: plan.mediaStoreDir,
      );
      ref.read(taskQueueProvider.notifier).enqueue([task]);
      final msg = plan.warning == null
          ? '已加入任务队列'
          : '${plan.warning}；已加入任务队列';
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    }
  }
}
