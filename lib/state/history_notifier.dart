import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models.dart';
import '../services/history_store.dart';

/// 一条转码历史（由任务数据落库后还原）。
class HistoryEntry {
  const HistoryEntry({
    required this.taskId,
    required this.kind,
    required this.inputName,
    required this.inputPath,
    required this.presetId,
    required this.presetName,
    required this.settings,
    required this.outputPath,
    required this.status,
    required this.createdAt,
    required this.finishedAt,
    this.inputBytes,
  });

  final String taskId;
  final MediaKind kind;
  final String inputName;
  final String inputPath;
  final String presetId;
  final String presetName;
  final ConvertSettings settings;
  final String outputPath;
  final TaskStatus status;
  final DateTime createdAt;
  final DateTime finishedAt;

  /// 源文件体积（字节），压缩任务展示前后体积对比用；null = 未知/旧记录。
  final int? inputBytes;

  static HistoryEntry fromRow(Map<String, Object?> row) {
    final rawSettings = (row['settings_json'] as String?) ?? '{}';
    final map = jsonDecode(rawSettings) as Map<String, dynamic>;
    final values = <SettingKey, String>{
      for (final e in SettingKey.values)
        if (map[e.name] is String) e: map[e.name] as String,
    };
    return HistoryEntry(
      taskId: row['id'] as String,
      kind: MediaKind.values[row['kind'] as int],
      inputName: row['input_name'] as String,
      inputPath: (row['input_path'] as String?) ?? '',
      presetId: (row['preset_id'] as String?) ?? '',
      presetName: (row['preset_name'] as String?) ?? '',
      settings: ConvertSettings(values),
      outputPath: (row['output_path'] as String?) ?? '',
      status: TaskStatus.values[row['status'] as int],
      createdAt:
          DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      finishedAt:
          DateTime.fromMillisecondsSinceEpoch(row['finished_at'] as int),
      inputBytes: row['input_bytes'] as int?,
    );
  }
}

final historyProvider = AsyncNotifierProvider<HistoryNotifier, List<HistoryEntry>>(
  HistoryNotifier.new,
);

class HistoryNotifier extends AsyncNotifier<List<HistoryEntry>> {
  @override
  Future<List<HistoryEntry>> build() async {
    final rows = await HistoryStore.all();
    return rows.map(HistoryEntry.fromRow).toList();
  }

  /// 重新从数据库加载（保存/删除后调用）。
  Future<void> refresh() async {
    state = AsyncData(await build());
  }

  Future<void> remove(String id) async {
    await HistoryStore.deleteById(id);
    await refresh();
  }

  Future<void> clearAll() async {
    await HistoryStore.deleteAll();
    await refresh();
  }
}
