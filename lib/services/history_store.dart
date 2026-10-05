import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models.dart';

/// 转码历史持久化（SQLite）。
/// 每个任务结束时写入/更新一行；以任务 id 为主键，重试后覆盖同一条。
class HistoryStore {
  HistoryStore._();

  static Database? _db;

  static Future<Database> _open() async {
    if (_db != null) return _db!;
    final db = await openDatabase(
      p.join(await getDatabasesPath(), 'history.db'),
      version: 2,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE history(
          id TEXT PRIMARY KEY,
          kind INTEGER NOT NULL,
          input_name TEXT NOT NULL,
          input_path TEXT,
          preset_id TEXT,
          preset_name TEXT,
          settings_json TEXT,
          output_path TEXT,
          status INTEGER NOT NULL,
          progress REAL,
          created_at INTEGER,
          finished_at INTEGER,
          input_bytes INTEGER
        )
      '''),
      // v2：新增 input_bytes（源文件体积，压缩任务展示前后体积对比用）
      onUpgrade: (db, _, _) async =>
          db.execute('ALTER TABLE history ADD COLUMN input_bytes INTEGER'),
    );
    _db = db;
    return db;
  }

  /// 保存一条任务记录（任务结束时调用）。
  static Future<void> save(ConvertTask task) async {
    final db = await _open();
    final settingsJson = jsonEncode({
      for (final e in task.settings.values.entries) e.key.name: e.value,
    });
    await db.insert(
      'history',
      {
        'id': task.id,
        'kind': task.kind.index,
        'input_name': task.inputName,
        'input_path': task.inputPath,
        'preset_id': task.presetId,
        'preset_name': task.presetName,
        'settings_json': settingsJson,
        'output_path': task.outputPath,
        'status': task.status.index,
        'progress': task.progress,
        'created_at': task.createdAt.millisecondsSinceEpoch,
        'finished_at': DateTime.now().millisecondsSinceEpoch,
        'input_bytes': task.inputBytes,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 全部历史（按结束时间倒序）。
  static Future<List<Map<String, Object?>>> all() async {
    final db = await _open();
    return db.query('history', orderBy: 'finished_at DESC');
  }

  static Future<void> deleteById(String id) async {
    final db = await _open();
    await db.delete('history', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deleteAll() async {
    final db = await _open();
    await db.delete('history');
  }
}
