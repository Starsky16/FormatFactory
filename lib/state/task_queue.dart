import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models.dart';
import '../services/compress_calc.dart';
import '../services/ffmpeg_engine.dart';
import '../services/foreground_notifier.dart';
import '../services/history_store.dart';
import '../services/storage_access.dart';
import '../services/unlock_api.dart';
import 'app_settings.dart';
import 'history_notifier.dart';

/// 全局任务队列（Riverpod 状态）。
///
/// 职责：
///   1. 维护全部任务列表（state）
///   2. 按"设置里的并行任务数"同时执行多个任务（默认串行 1）
///   3. 把 FFmpeg 的进度统计换算成 0~1 的 progress 写回任务
///   4. 支持取消任务 / 清空队列 / 失败重试
final taskQueueProvider =
    NotifierProvider<TaskQueue, List<ConvertTask>>(TaskQueue.new);

/// 按分段设置把 [base] 展开成多个任务（入队前调用）。
///
/// 填了 segmentMinutes（每段分钟数）时按 [segmentBounds] 切段：
///   - 每段生成一个任务，各自覆写 trimStart/trimEnd，输出名加 `_partN`
///   - 压缩任务（video_compress）把目标体积按段均分（余数给前几段）
/// 未填分段、段秒非法、无源时长或只切出 1 段时，原样返回 [base]。
List<ConvertTask> expandSegments(ConvertTask base) {
  final minutes =
      double.tryParse(base.settings.of(SettingKey.segmentMinutes).trim());
  if (minutes == null || minutes <= 0) return [base];
  final segs = segmentBounds(
    durationSeconds: base.inputDurationSeconds ?? 0,
    segmentSeconds: minutes * 60,
    trimStart: base.settings.of(SettingKey.trimStart),
    trimEnd: base.settings.of(SettingKey.trimEnd),
  );
  if (segs.length <= 1) return [base];

  final isCompress = base.presetId == FfmpegEngine.compressPresetId;
  final targetMB =
      int.tryParse(base.settings.of(SettingKey.targetVolumeMB).trim());
  final n = segs.length;

  return [
    for (var i = 0; i < n; i++)
      _segmentTask(base, segs[i],
          part: i + 1, perVolumeMB: isCompress && targetMB != null && targetMB > 0
              ? (targetMB ~/ n + (i < targetMB % n ? 1 : 0)).clamp(1, targetMB)
              : null),
  ];
}

/// 生成一个分段任务：覆写裁剪边界与（可选）每段目标体积。
ConvertTask _segmentTask(
  ConvertTask base,
  SegmentRange seg, {
  required int part,
  int? perVolumeMB,
}) {
  final values = Map.of(base.settings.values)
    ..[SettingKey.trimStart] = formatClock(seg.start)
    ..[SettingKey.trimEnd] = formatClock(seg.end);
  if (perVolumeMB != null) {
    values[SettingKey.targetVolumeMB] = '$perVolumeMB';
  }
  return ConvertTask(
    // id 必须唯一：_patch/取消/历史都按 id 找任务
    id: '${base.id}_p$part',
    kind: base.kind,
    inputPath: base.inputPath,
    inputName: base.inputName,
    presetId: base.presetId,
    presetName: base.presetName,
    settings: ConvertSettings(values),
    outputPath: _partPath(base.outputPath, part),
    createdAt: base.createdAt,
    unlockFormat: base.unlockFormat,
    mergeAudioPath: base.mergeAudioPath,
    safTreeUri: base.safTreeUri,
    mediaStoreDir: base.mediaStoreDir,
    inputDurationSeconds: base.inputDurationSeconds,
    inputBytes: base.inputBytes,
    inputHasAttachedPic: base.inputHasAttachedPic,
  );
}

/// '/out/a.mp4' + 2 -> '/out/a_part2.mp4'（无扩展名时追加在尾部）。
String _partPath(String path, int part) {
  final dot = path.lastIndexOf('.');
  final slash = path.lastIndexOf('/');
  if (dot < 0 || dot < slash) return '${path}_part$part';
  return '${path.substring(0, dot)}_part$part${path.substring(dot)}';
}

/// 单条 FFmpeg 命令的执行结果。
enum _ExecResult { success, failed, canceled }

class TaskQueue extends Notifier<List<ConvertTask>> {
  /// 正在运行的任务数（不应超过并行上限）。
  int _active = 0;

  /// 各运行中 FFmpeg 任务对应的会话（用于逐个取消）。
  final Map<String, FFmpegSession> _sessions = {};

  /// 已请求取消、但原生通道不支持中途取消的脱壳任务 id（完成时按取消处理）。
  final Set<String> _cancelRequested = {};

  /// 当前允许并行的任务数（来自设置）。
  int get _maxConcurrent =>
      ref.read(appSettingsProvider).concurrentTasks.clamp(1, 8);

  /// 通知进度节流：记录上次通知的整百分比。
  int _lastNotifiedPct = -1;

  /// [finishOnFail] 为假（硬编试跑）失败时暂存的原因，回退软编时参考。
  String? _lastFailMessage;

  /// 通知开关是否开启。
  bool get _notifyEnabled =>
      ref.read(appSettingsProvider).notificationsEnabled;

  /// 生成一个大概率不重复的任务 id。
  static String newId() =>
      't${DateTime.now().microsecondsSinceEpoch}';

  @override
  List<ConvertTask> build() => [];

  /// 按 id 修改列表中某个任务（找不到就忽略）。
  void _patch(String id, ConvertTask Function(ConvertTask) change) {
    final i = state.indexWhere((t) => t.id == id);
    if (i < 0) return;
    final next = List<ConvertTask>.from(state);
    next[i] = change(state[i]);
    state = next;
  }

  // ---------- 队列控制 ----------

  /// 把一批任务加入队列，并尝试启动下一个。
  void enqueue(List<ConvertTask> tasks) {
    if (tasks.isEmpty) return;
    state = [...state, ...tasks];
    _pump();
  }

  /// 调度：只要还有空闲"并行槽位"，就依次启动排队中的任务。
  void _pump() {
    while (_active < _maxConcurrent) {
      final i = state.indexWhere((t) => t.status == TaskStatus.queued);
      if (i < 0) break;
      _active++;
      _run(state[i]);
    }
  }

  Future<void> _run(ConvertTask task) async {
    _patch(task.id, (t) => t.copyWith(status: TaskStatus.running, progress: 0));

    // 后台通知：开启时启动前台服务并显示初始进度
    _lastNotifiedPct = -1;
    if (_notifyEnabled) {
      await ForegroundNotifier.start();
      await _notify(task, 0);
    }

    // 脱壳任务：走原生解密通道，不进 FFmpeg
    if (task.unlockFormat != null) {
      await _runUnlock(task);
      return;
    }

    try {
      if (task.presetId == FfmpegEngine.compressPresetId) {
        await _runCompress(task);
      } else {
        final ok = await _execute(task, FfmpegEngine.buildCommand(task));
        if (ok == _ExecResult.success) await _saveToTarget(task);
      }
    } catch (e) {
      _finish(task, message: '启动 FFmpeg 失败：$e');
    }
  }

  /// 压缩任务执行：默认 MediaCodec 硬编单遍（快 5~10×，体积精度略降）；
  /// 编码器不可用或硬编失败时自动回退软编两遍（精确命中目标体积）。
  ///
  /// 实际用的编码器写进任务参数摘要（videoEncoder），用户在任务列表
  /// 可直接看到"硬件/软件"——硬编静默不可用时不再无迹可寻。
  Future<void> _runCompress(ConvertTask task) async {
    if (await FfmpegEngine.hwEncoderAvailable()) {
      _markEncoder(task, 'h264_mediacodec（硬件）');
      final r = await _execute(
        task,
        FfmpegEngine.buildHardwareCompressCommand(task),
        finishOnFail: false, // 失败先不收尾，留给回退逻辑
      );
      if (r == _ExecResult.success) {
        await _saveToTarget(task);
        return;
      }
      if (r == _ExecResult.canceled) {
        _finish(task, canceled: true);
        return;
      }
      // 硬编失败 → 置回 running，用软编两遍重跑（失败原因记进 error 供排查）
      _patch(task.id, (x) => x.copyWith(
            status: TaskStatus.running,
            progress: 0,
            error: '硬编失败，已自动回退软编：${_lastFailMessage ?? '未知原因'}',
          ));
      _markEncoder(task, 'libx264（软件，硬编失败回退）');
      if (_notifyEnabled) await _notify(task, 0);
    } else {
      _markEncoder(task, 'libx264（软件，设备未探测到硬编）');
    }
    final pass1 = await _execute(
        task, FfmpegEngine.buildCompressCommand(task, pass: 1));
    if (pass1 != _ExecResult.success) return; // 失败/取消已在 _execute 收尾
    final ok = await _execute(task, FfmpegEngine.buildCommand(task));
    if (ok == _ExecResult.success) await _saveToTarget(task);
  }

  /// 执行一条 FFmpeg 命令并等它结束。
  ///
  /// 默认 [finishOnFail] 为真：失败/取消当场 [_finish] 收尾（推进队列），
  /// 返回值只用于让调用方停止后续步骤。
  /// [finishOnFail] 为假（硬编试跑）：失败/取消不收尾、不推进队列，
  /// 失败原因暂存 [_lastFailMessage]，由调用方决定回退或收尾。
  Future<_ExecResult> _execute(
    ConvertTask task,
    String command, {
    bool finishOnFail = true,
  }) async {
    final done = Completer<_ExecResult>();
    var result = _ExecResult.failed;
    try {
      final session = await FFmpegKit.executeAsync(
        command,
        // 完成回调：按返回码分流；成功交给调用方继续
        (s) async {
          try {
            final rc = await s.getReturnCode();
            if (ReturnCode.isSuccess(rc)) {
              result = _ExecResult.success;
            } else if (ReturnCode.isCancel(rc)) {
              result = _ExecResult.canceled;
              if (finishOnFail) _finish(task, canceled: true);
            } else {
              final stack = await s.getFailStackTrace();
              final logs = await _tail(s);
              var message =
                  stack ?? logs ?? 'FFmpeg 执行失败（返回码 $rc）';
              // 全量日志落盘，失败卡片可查看完整输出（大文件被系统杀进程
              // 时尾巴日志往往抓不到关键行）
              final logPath = await _dumpLogs(task, s);
              if (logPath != null) message = '$message\n完整日志：$logPath';
              if (finishOnFail) {
                _finish(task, message: message);
              } else {
                _lastFailMessage = message;
              }
            }
          } finally {
            if (!done.isCompleted) done.complete(result);
          }
        },
        // 日志回调：这里只收集，不处理（出错时用 getAllLogsAsString 取尾巴）
        (log) {},
        // 统计回调：time 是已经处理到的视频时间(毫秒)，用它算百分比
        (stat) {
          final durationMs = (task.inputDurationSeconds ?? 0) * 1000;
          if (durationMs <= 0) return;
          final p = (stat.getTime() / durationMs).clamp(0.0, 1.0);
          _patch(task.id, (t) => t.copyWith(progress: p));
          // 进度通知做节流：每 +2% 才刷新一次
          if (_notifyEnabled) {
            final pct = (p * 100).round();
            if (pct >= _lastNotifiedPct + 2) {
              _lastNotifiedPct = pct;
              unawaited(_notify(task, p));
            }
          }
        },
      );
      _sessions[task.id] = session;
    } catch (e) {
      _finish(task, message: '启动 FFmpeg 失败：$e');
      return _ExecResult.failed;
    }
    final r = await done.future;
    _sessions.remove(task.id);
    return r;
  }

  /// 把实际使用的视频编码器写进任务参数摘要（summary 会显示）。
  void _markEncoder(ConvertTask task, String label) {
    _patch(task.id, (x) => x.copyWith(
          settings: ConvertSettings(<SettingKey, String>{
            ...x.settings.values,
            SettingKey.videoEncoder: label,
          }),
        ));
  }

  /// 把 FFmpeg 全量日志写到输出文件旁的 .log（失败排查用）。
  Future<String?> _dumpLogs(ConvertTask task, FFmpegSession s) async {
    try {
      final logs = await s.getAllLogsAsString();
      if (logs == null || logs.trim().isEmpty) return null;
      final path = '${task.outputPath}.log';
      File(path).writeAsStringSync(logs, flush: true);
      return path;
    } catch (_) {
      return null;
    }
  }

  /// 执行"脱壳"任务：调用原生解锁通道得到原始音频，再走统一的"输出到目标"流程。
  Future<void> _runUnlock(ConvertTask task) async {
    try {
      final r = await UnlockApi.unlockMusic(
        format: task.unlockFormat!,
        src: task.inputPath,
        destDir: task.outputPath,
      );

      // 把输出路径更新为解密后的真实文件，再与转换流程一致地收尾（含通知/历史/SAF复制）
      final done = task.copyWith(outputPath: r.path, progress: 1.0);
      _patch(done.id, (_) => done);
      // 若在脱壳过程中用户请求取消（原生不支持中途停），按"已取消"收尾。
      // 注意要传 done（outputPath 已换成真实产物），否则 _finish 里的
      // "删除半成品"会拿到输出目录、删不掉文件。
      if (_cancelRequested.remove(task.id)) {
        _finish(done, canceled: true);
        return;
      }
      if (_notifyEnabled) {
        unawaited(_notify(done, 1.0));
      }
      await _saveToTarget(done);
    } catch (e) {
      _finish(
        task,
        message: '脱壳失败：${e.toString().replaceFirst('Exception: ', '')}',
      );
    }
  }

  /// 转换成功后把产物搬到用户可见位置：
  ///  - [ConvertTask.safTreeUri] 非空：复制进用户自选的 SAF 目录
  ///  - [ConvertTask.mediaStoreDir] 非空：导入系统"下载"目录（默认输出的无权限兜底）
  ///  - 两者都为空：产物已经落在最终位置，直接收尾
  /// 搬运成功时内部工作区会**保留**一份副本，供"任务"页分享使用。
  Future<void> _saveToTarget(ConvertTask task) async {
    final tree = task.safTreeUri;
    final downloads = task.mediaStoreDir;
    if (tree == null && downloads == null) {
      _finish(task, succeeded: true);
      return;
    }
    final fileName = _fileName(task.outputPath);
    final uri = tree != null
        ? await StorageAccess.copyToTree(
            treeUri: tree,
            fileName: fileName,
            srcPath: task.outputPath,
          )
        : await StorageAccess.copyToDownloads(
            relativeDir: downloads!,
            fileName: fileName,
            srcPath: task.outputPath,
          );
    if (uri == null) {
      _finish(
        task,
        message: tree != null
            ? '已转换完成，但写入所选目录失败（目录可能已失效或被删）。\n'
                '可重试，或在设置里把输出位置改回"默认目录"。'
            : '已转换完成，但保存到系统"下载"目录失败（可能是空间不足或系统限制）。\n'
                '可重试，或在设置里把输出位置改成"应用专属目录"。',
      );
      return;
    }
    _finish(task, succeeded: true);
  }

  /// 取路径最后一段作为文件名。
  static String _fileName(String path) {
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf('\\');
    return path.substring((slash > backslash ? slash : backslash) + 1);
  }

  /// 更新一条通知内容。
  Future<void> _notify(ConvertTask task, double p) async {
    final active = state.where((t) => !t.status.isFinished).length;
    final title = active > 1 ? '正在转换，剩余 $active 个任务' : '正在转换…';
    final rawName = task.inputName;
    final name = rawName.length > 30
        ? '${rawName.substring(0, 30)}…'
        : rawName;
    await ForegroundNotifier.update(
      title: title,
      text: '$name ${(p * 100).round()}%',
    );
  }

  /// 把已结束的任务写入历史库并刷新历史列表。
  Future<void> _archive(String id) async {
    final row = state.where((t) => t.id == id).firstOrNull;
    if (row == null) return;
    try {
      await HistoryStore.save(row);
      await ref.read(historyProvider.notifier).refresh();
    } catch (_) {
      // 历史写失败不阻塞主流程
    }
  }

  /// 结束当前任务并调度下一个。
  void _finish(
    ConvertTask task, {
    bool succeeded = false,
    bool canceled = false,
    String? message,
  }) {
    _active = _active > 0 ? _active - 1 : 0;
    _sessions.remove(task.id);
    _cancelRequested.remove(task.id);

    final status =
        canceled ? TaskStatus.canceled : (succeeded ? TaskStatus.succeeded : TaskStatus.failed);

    _patch(task.id, (t) {
      final updated = t.copyWith(
        status: status,
        progress: succeeded ? 1.0 : t.progress,
        error: message,
      );
      return updated;
    });

    // 任务已结束 → 写入转码历史
    unawaited(_archive(task.id));

    // 失败/取消时清掉可能留下的半截输出文件
    if (!succeeded) {
      _deleteOutput(task.outputPath);
    } else {
      // 成功时清掉早前失败留下的日志文件
      _deleteOutput('${task.outputPath}.log');
    }
    // 压缩任务无论成败都清掉两遍编码的 passlog 统计文件
    if (task.presetId == FfmpegEngine.compressPresetId) {
      _deleteOutput(FfmpegEngine.passlogPath(task));
    }
    _pump();
    // 队列已空：停止前台服务/通知
    if (_notifyEnabled && !state.any((t) => !t.status.isFinished)) {
      unawaited(ForegroundNotifier.stop());
    }
  }

  static void _deleteOutput(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  static Future<String?> _tail(FFmpegSession s) async {
    try {
      final logs = await s.getAllLogsAsString(2000);
      if (logs == null) return null;
      final lines = logs.trim().split('\n');
      return lines.length > 8 ? lines.sublist(lines.length - 8).join('\n') : logs;
    } catch (_) {
      return null;
    }
  }

  // ---------- 供界面调用的操作 ----------

  /// 取消一个任务：正在转码的立刻中断，排队的直接标记取消；
  /// 运行中的脱壳任务（原生不支持中途停）在完成后按已取消收尾。
  Future<void> cancel(String id) async {
    final task = state.where((t) => t.id == id).firstOrNull;
    if (task == null) return;
    if (task.status == TaskStatus.queued) {
      _patch(id, (t) => t.copyWith(status: TaskStatus.canceled));
      return;
    }
    if (task.status == TaskStatus.running) {
      final session = _sessions[id];
      if (session != null) {
        await session.cancel(); // FFmpeg 完成后会走到 _finish(canceled: true)
      } else {
        _cancelRequested.add(id); // 脱壳任务：完成后转"已取消"
      }
    }
  }

  /// 取消所有排队任务（正在转码的也一并中断）。
  Future<void> cancelAll() async {
    for (final t in state) {
      if (t.status == TaskStatus.queued) {
        _patch(t.id, (x) => x.copyWith(status: TaskStatus.canceled));
      }
    }
    for (final e in _sessions.entries) {
      await e.value.cancel();
    }
    for (final t in state) {
      if (t.status == TaskStatus.running &&
          t.unlockFormat != null &&
          !_sessions.containsKey(t.id)) {
        _cancelRequested.add(t.id);
      }
    }
  }

  /// 失败/取消的任务重试（重新排队，清空错误）。
  void retry(String id) {
    _patch(id,
        (t) => t.copyWith(status: TaskStatus.queued, progress: 0, clearError: true));
    _pump();
  }

  /// 从列表删除一个任务（仅供已完成/失败等"不会再跑"的任务使用）。
  void remove(String id) {
    state = state.where((t) => t.id != id).toList();
  }

  /// 清空所有"已经结束"的任务。
  void clearFinished() {
    state = state.where((t) => !t.status.isFinished).toList();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
