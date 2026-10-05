import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../models.dart';
import '../services/compress_calc.dart';
import '../services/ffmpeg_engine.dart';
import '../state/task_queue.dart';

/// 任务列表页：显示全部任务、实时进度，支持取消/重试/分享。
class TasksPage extends ConsumerWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(taskQueueProvider);
    if (tasks.isEmpty) return const _EmptyTasks();

    // 排序：未结束的在前，同样状态按创建时间倒序
    final sorted = List<ConvertTask>.from(tasks)
      ..sort((a, b) {
        final af = a.status.isFinished ? 1 : 0;
        final bf = b.status.isFinished ? 1 : 0;
        if (af != bf) return af - bf;
        return b.createdAt.compareTo(a.createdAt);
      });

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: sorted.length,
      itemBuilder: (context, i) => _TaskTile(task: sorted[i]),
    );
  }
}

class _EmptyTasks extends StatelessWidget {
  const _EmptyTasks();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.playlist_add_check_circle_outlined,
                size: 72,
                color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            const Text('暂无任务'),
            const SizedBox(height: 8),
            Text(
              '到"转换"页选择文件并开始转换，任务会显示在这里',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task});

  final ConvertTask task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = task.status;
    final statusColor = switch (status) {
      TaskStatus.queued => scheme.outline,
      TaskStatus.running => scheme.primary,
      TaskStatus.succeeded => const Color(0xFF2E7D32),
      TaskStatus.failed => scheme.error,
      TaskStatus.canceled => scheme.outline,
    };

    final actions = <Widget>[];
    if (status == TaskStatus.running || status == TaskStatus.queued) {
      actions.add(IconButton(
        icon: const Icon(Icons.stop_circle_outlined),
        tooltip: '取消',
        color: scheme.error,
        onPressed: () => _notifier(context).cancel(task.id),
      ));
    }
    if (status == TaskStatus.failed || status == TaskStatus.canceled) {
      actions.add(IconButton(
        icon: const Icon(Icons.refresh),
        tooltip: '重试',
        onPressed: () => _notifier(context).retry(task.id),
      ));
    }
    if (status == TaskStatus.succeeded) {
      actions.add(IconButton(
        icon: const Icon(Icons.share_outlined),
        tooltip: '分享文件',
        onPressed: () => _share(context),
      ));
    }
    if (status.isFinished) {
      actions.add(IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: '删除记录',
        onPressed: () => _notifier(context).remove(task.id),
      ));
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: statusColor.withValues(alpha: 0.14),
              child:
                  Icon(_statusIcon(status), color: statusColor, size: 20),
            ),
            title: Text(task.inputName,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                Text(
                  '${task.presetName} · ${task.settings.summary}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (status == TaskStatus.succeeded)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _effectLine,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.outline),
                    ),
                  ),
              ],
            ),
            trailing: status.isFinished
                ? null
                : Text(status.label, style: TextStyle(color: statusColor)),
            onTap: (status == TaskStatus.failed && task.error != null)
                ? () => _showError(context)
                : null,
          ),
          if (status == TaskStatus.running)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  LinearProgressIndicator(
                    value: task.progress > 0 ? task.progress : null,
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    task.progress > 0
                        ? '${(task.progress * 100).round()}%'
                        : '准备中…',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            )
          else if (status == TaskStatus.queued)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('等待前面的任务完成…',
                    style: theme.textTheme.bodySmall),
              ),
            ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 4, bottom: 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: Wrap(spacing: 0, children: actions),
              ),
            ),
        ],
      ),
    );
  }

  /// 成功后的一行说明：
  ///  - 压缩任务：显示"压前 → 压后（−xx%）"体积对比，外加所在位置
  ///  - 其他任务：显示"文件在哪"
  ///  - SAF / 系统下载目录：提示已搬运，并说明内部仍留一份可分享的副本
  String get _effectLine {
    final out = File(task.outputPath);
    final outBytes = out.existsSync() ? out.lengthSync() : 0;
    final where = _outputLine;
    if (task.presetId == FfmpegEngine.compressPresetId &&
        task.inputBytes != null) {
      final effect = compressEffectText(task.inputBytes!, outBytes);
      return effect.isEmpty ? where : '$effect · $where';
    }
    return where;
  }

  /// "文件在哪"的一行说明：
  ///  - 直接写最终目录（默认目录 / 应用专属目录）：显示真实路径
  ///  - SAF / 系统下载目录：提示已搬运，并说明内部仍留一份可分享的副本
  String get _outputLine {
    if (task.safTreeUri != null) {
      return '已保存到你选择的目录（内部另留一份可分享的副本）';
    }
    if (task.mediaStoreDir != null) {
      return '已保存到系统"下载"目录 ${task.mediaStoreDir}（内部另留一份可分享的副本）';
    }
    return task.outputPath;
  }

  IconData _statusIcon(TaskStatus s) => switch (s) {
        TaskStatus.queued => Icons.schedule,
        TaskStatus.running => Icons.autorenew,
        TaskStatus.succeeded => Icons.check_circle_outline,
        TaskStatus.failed => Icons.error_outline,
        TaskStatus.canceled => Icons.cancel_outlined,
      };

  TaskQueue _notifier(BuildContext context) => ProviderScope.containerOf(
        context,
        listen: false,
      ).read(taskQueueProvider.notifier);

  void _showError(BuildContext context) {
    // 失败时 FFmpeg 全量日志已落盘（输出文件旁的 .log），一并展示便于排查
    var detail = task.error ?? '未知错误';
    final log = File('${task.outputPath}.log');
    if (log.existsSync()) {
      var content = log.readAsStringSync();
      // 日志可能非常大，弹窗里只放末尾 4000 字符
      if (content.length > 4000) {
        content = content.substring(content.length - 4000);
      }
      detail = '$detail\n\n―― FFmpeg 日志末尾（完整日志见 ${log.path}）――\n$content';
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('失败原因'),
        content: SingleChildScrollView(
          child: SelectableText(detail,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
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

  Future<void> _share(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!File(task.outputPath).existsSync()) {
      messenger
          .showSnackBar(const SnackBar(content: Text('文件不存在，可能已被删除')));
      return;
    }
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(task.outputPath)]),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('分享失败：$e')));
    }
  }
}

