import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

/// "文件管理权限"读取方式下的自建文件浏览器。
/// 允许在目录间跳转、多选支持格式的文件，确定后把选中文件的路径 pop 回上一页。
class FileBrowserPage extends StatefulWidget {
  const FileBrowserPage({
    super.key,
    required this.extensions,
    this.pickDirectory = false,
    this.initialPath,
    this.title,
  });

  /// 允许选择的扩展名（小写，不带点）。
  final List<String> extensions;

  /// 选目录模式：只列目录，底部按钮把「当前目录路径」pop 回上一页。
  /// （B站缓存这类需要"整个目录"的入口用它。）
  final bool pickDirectory;

  /// 打开时直接进入的目录（选目录模式常用）。
  final String? initialPath;

  /// 自定义标题（选目录模式常用，如"选择 B站缓存目录"）。
  final String? title;

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  /// 当前目录（打开时会在 initState 里按 initialPath 定位）
  late Directory _current;
  final List<String> _stack = [];
  final Set<String> _selected = {};

  bool get _atStorageRoot => _current.path == '/storage';
  bool get _atPrimary => _current.path == '/storage/emulated/0';

  // ===== 搜索状态 =====
  bool _searching = false;
  bool _searchingNow = false;
  final TextEditingController _searchCtrl = TextEditingController();
  String _keyword = '';
  final List<_SearchHit> _hits = [];

  // ===== 书签状态 =====
  static const String _kBookmarks = 'file_browser.bookmarks';
  List<String> _bookmarks = [];

  /// 常用快捷位置
  static const List<(String, String)> _quickPlaces = [
    ('分区列表', '/storage'),
    ('主存储', '/storage/emulated/0'),
    ('下载 Download', '/storage/emulated/0/Download'),
    ('图片 DCIM', '/storage/emulated/0/DCIM'),
    ('图片 Pictures', '/storage/emulated/0/Pictures'),
    ('音乐 Music', '/storage/emulated/0/Music'),
    ('影片 Movies', '/storage/emulated/0/Movies'),
  ];

  @override
  void initState() {
    super.initState();
    // 默认进主存储（照片/下载/Music 都在这里）；给了 initialPath 就直接进去
    _current = Directory(widget.initialPath ?? '/storage/emulated/0');
    _loadBookmarks();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBookmarks() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getStringList(_kBookmarks) ?? const [];
    if (!mounted) return;
    setState(() => _bookmarks = List.of(saved));
  }

  Future<void> _persistBookmarks() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kBookmarks, _bookmarks);
  }

  /// 直接跳到一个目录（清空导航历史，退出搜索）。
  void _jumpTo(String path) {
    setState(() {
      _searching = false;
      _hits.clear();
      _keyword = '';
      _searchCtrl.clear();
      _stack.clear();
      _current = Directory(path);
    });
  }

  /// 进入子目录（把当前目录压栈，便于返回）
  void _enter(Directory d) {
    _stack.add(_current.path);
    setState(() => _current = d);
  }

  /// 返回上级：主存储 → 分区选择；更深目录 → 上一级
  void _goUp() {
    if (_atStorageRoot) return;
    if (_atPrimary) {
      _stack.clear();
      setState(() => _current = Directory('/storage'));
      return;
    }
    if (_stack.isEmpty) {
      // 用 initialPath 直接打开时没有历史栈：退回主存储，避免崩溃
      setState(() => _current = Directory('/storage/emulated/0'));
      return;
    }
    setState(() => _current = Directory(_stack.removeLast()));
  }

  /// 当前目录的短标签，用于"选择此目录"按钮。
  String get _currentLabel {
    if (_atStorageRoot) return '分区列表';
    if (_atPrimary) return '主存储';
    final parts =
        _current.path.split('/').where((e) => e.isNotEmpty).toList();
    if (parts.length >= 2) return '${parts[parts.length - 2]}/${parts.last}';
    return _current.path;
  }

  bool _match(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return widget.extensions.contains(name.substring(dot + 1).toLowerCase());
  }

  /// 全选当前可见的可转换文件（目录模式=当前目录文件；搜索模式=搜索结果文件）。
  void _selectAllVisible() {
    setState(() {
      if (_searching) {
        for (final h in _hits) {
          if (!h.isDir) _selected.add(h.path);
        }
        return;
      }
      try {
        for (final e in _current.listSync()) {
          if (e is File && _match(e.path)) _selected.add(e.path);
        }
      } catch (_) {}
    });
  }

  void _clearSelection() {
    setState(() => _selected.clear());
  }

  void _toggle(String path) {
    setState(() {
      if (!_selected.remove(path)) _selected.add(path);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: _searching
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: '退出搜索',
                onPressed: _exitSearch,
              ),
              title: TextField(
                controller: _searchCtrl,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: '在当前目录及子目录中搜索…',
                  border: InputBorder.none,
                ),
                onSubmitted: (_) => _runSearch(),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: '搜索',
                  onPressed: _runSearch,
                ),
              ],
            )
          : AppBar(
              title: Text(
                _atStorageRoot
                    ? '选择分区'
                    : widget.title ??
                        (_atPrimary
                            ? '主存储 (emulated/0)'
                            : _current.path.split('/').last),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              leading: _atStorageRoot
                  ? null // 分区选择页：返回键=退出浏览器
                  : IconButton(
                      icon: const Icon(Icons.arrow_upward),
                      onPressed: _goUp,
                    ),
              actions: [
                // 选目录模式不需要搜索文件
                if (!widget.pickDirectory)
                  IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: '搜索文件',
                    onPressed: _startSearch,
                  ),
                IconButton(
                  icon: Icon(
                    _bookmarks.contains(_current.path)
                        ? Icons.bookmark
                        : Icons.bookmark_border,
                  ),
                  tooltip: '书签与快捷位置',
                  onPressed: () => _openBookmarks(context),
                ),
              ],
            ),
      body: _searching
          ? _searchView(theme)
          : _atStorageRoot
              ? _rootView(theme)
              : FutureBuilder<List<FileSystemEntity>>(
              future: _listSafe(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        '无法读取该目录（可能没有访问权限或目录已不可用）：\n${snap.error}\n\n'
                        '请确认已开启"文件管理权限"，再返回上一级目录重试。\n'
                        '若权限已开启仍报错（尤其刚在系统设置里授权过），'
                        '请完全退出本应用（从最近任务里划掉）后重新打开。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  );
                }
                return _fileList(theme, snap.data ?? const []);
              },
            ),
      bottomNavigationBar: _bottomBar(),
    );
  }

  /// 底部操作条：
  ///  - 选目录模式：返回「当前目录」
  ///  - 选文件模式：全选 / 清除 / 确定添加
  Widget _bottomBar() {
    if (widget.pickDirectory) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: _atStorageRoot
                ? null
                : () => Navigator.of(context).pop(<String>[_current.path]),
            icon: const Icon(Icons.check),
            label: Text('选择此目录 · $_currentLabel'),
          ),
        ),
      );
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            TextButton.icon(
              onPressed:
                  (_atStorageRoot && !_searching) ? null : _selectAllVisible,
              icon: const Icon(Icons.select_all, size: 18),
              label: const Text('全选'),
            ),
            TextButton.icon(
              onPressed: _selected.isEmpty ? null : _clearSelection,
              icon: const Icon(Icons.deselect, size: 18),
              label: const Text('清除'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: _selected.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(_selected.toList()),
                icon: const Icon(Icons.check),
                label: Text('确定添加 (${_selected.length})'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<List<FileSystemEntity>> _listSafe() async {
    final list = _current.list().toList();
    return list;
  }

  /// 根目录：列出主存储与其它顶层目录。
  Widget _rootView(ThemeData theme) {
    final storage = Directory('/storage');
    final roots = <Directory>[];
    try {
      roots.addAll(storage.listSync().whereType<Directory>());
    } catch (_) {}
    if (roots.isEmpty) {
      return const Center(child: Text('未找到可访问的存储目录'));
    }
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text('快捷进入主存储，或选择其它分区（可多选文件）',
              style: theme.textTheme.bodySmall),
        ),
        ListTile(
          leading: const Icon(Icons.folder_special),
          title: const Text('主存储 · /storage/emulated/0'),
          subtitle: const Text('照片 / 下载 / Music 等默认目录',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => _enter(Directory('/storage/emulated/0')),
        ),
        for (final d in roots)
          if (d.path != '/storage/emulated')
            ListTile(
              leading: const Icon(Icons.folder),
              title: Text(d.path),
              onTap: () => _enter(d),
            ),
      ],
    );
  }

  Widget _fileList(ThemeData theme, List<FileSystemEntity> entries) {
    final dirs = <Directory>[];
    final files = <File>[];
    for (final e in entries) {
      if (e is Directory) dirs.add(e);
      // 选目录模式只列目录：B站缓存里的 m4s/json 没有单独选择的意义
      if (!widget.pickDirectory && e is File && _match(e.path)) files.add(e);
    }
    dirs.sort((a, b) => a.path.compareTo(b.path));
    files.sort((a, b) => a.path.compareTo(b.path));

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(_current.path,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
        ),
        for (final d in dirs)
          ListTile(
            dense: true,
            leading: const Icon(Icons.folder_outlined),
            title: Text(d.path.split(Platform.pathSeparator).last,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => _enter(d),
          ),
        for (final f in files)
          ListTile(
            dense: true,
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: Text(f.uri.pathSegments.last,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(formatBytes(_sizeOf(f))),
            trailing: Icon(
              _selected.contains(f.path)
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              color: _selected.contains(f.path)
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            onTap: () => _toggle(f.path),
          ),
        if (dirs.isEmpty && files.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(widget.pickDirectory
                  ? '此目录没有子目录：可直接用下方按钮选择当前目录'
                  : '此目录没有可转换的文件'),
            ),
          ),
      ],
    );
  }

  static int _sizeOf(File f) {
    try {
      return f.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  // ===================== 搜索 =====================

  void _startSearch() {
    setState(() {
      _searching = true;
      _searchingNow = false;
      _keyword = '';
      _hits.clear();
    });
  }

  void _exitSearch() {
    setState(() {
      _searching = false;
      _searchingNow = false;
      _keyword = '';
      _hits.clear();
      _searchCtrl.clear();
    });
  }

  Future<void> _runSearch() async {
    final kw = _searchCtrl.text.trim();
    if (kw.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入要搜索的关键字')));
      return;
    }
    setState(() {
      _keyword = kw.toLowerCase();
      _searchingNow = true;
      _hits.clear();
    });
    final out = <_SearchHit>[];
    await _collect(_current, 0, _keyword, out);
    if (!mounted) return;
    setState(() {
      _searchingNow = false;
      _hits.addAll(out);
    });
  }

  /// 递归搜索：当前目录往下最多 3 层、最多 800 条结果，避免卡顿。
  Future<void> _collect(
    Directory dir,
    int depth,
    String kw,
    List<_SearchHit> out,
  ) async {
    if (depth > 3 || out.length >= 800) return;
    List<FileSystemEntity> children;
    try {
      children = await dir.list().toList();
    } catch (_) {
      return; // 无权限目录直接跳过
    }
    for (final e in children) {
      if (out.length >= 800) return;
      final name = e.path.split('/').last;
      final matched = name.toLowerCase().contains(kw);
      if (e is Directory) {
        if (matched) {
          out.add(_SearchHit(isDir: true, path: e.path, name: name));
        }
        await _collect(e, depth + 1, kw, out);
      } else if (e is File) {
        if (matched && _match(e.path)) {
          out.add(_SearchHit(isDir: false, path: e.path, name: name));
        }
      }
    }
  }

  Widget _searchView(ThemeData theme) {
    if (_searchingNow) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_keyword.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '输入关键字后点搜索\n会递归查找当前目录的子目录（最多 3 层）',
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.outline),
          ),
        ),
      );
    }
    if (_hits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '没有找到匹配的文件\n（仅统计可转换扩展名；最多搜索 3 层 / 800 条）',
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.outline),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _hits.length,
      itemBuilder: (context, i) {
        final h = _hits[i];
        if (h.isDir) {
          return ListTile(
            dense: true,
            leading: const Icon(Icons.folder_outlined),
            title: Text(h.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle:
                Text(h.path, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () {
              _enter(Directory(h.path)); // 进入该目录继续浏览
              _exitSearch();
            },
          );
        }
        return ListTile(
          dense: true,
          leading: const Icon(Icons.insert_drive_file_outlined),
          title: Text(h.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle:
              Text(h.path, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Icon(
            _selected.contains(h.path)
                ? Icons.check_circle
                : Icons.radio_button_unchecked,
            color: _selected.contains(h.path)
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
          ),
          onTap: () => _toggle(h.path),
        );
      },
    );
  }

  // ===================== 书签 =====================

  /// 收藏/取消收藏某个目录。
  void _toggleBookmarkPath(String path) {
    final i = _bookmarks.indexOf(path);
    setState(() {
      if (i >= 0) {
        _bookmarks.removeAt(i);
      } else {
        _bookmarks.add(path);
      }
    });
    _persistBookmarks();
  }

  void _removeBookmark(String path) {
    setState(() => _bookmarks.remove(path));
    _persistBookmarks();
  }

  /// 弹出"书签与快捷位置"面板；点选后跳转到该目录。
  Future<void> _openBookmarks(BuildContext context) async {
    final current = _current.path;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final saved = List.of(_bookmarks);
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.72,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    leading: const Icon(Icons.bookmark_add_outlined),
                    title: const Text('收藏当前目录'),
                    subtitle: Text(current,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: Icon(
                        saved.contains(current)
                            ? Icons.bookmark
                            : Icons.bookmark_border,
                      ),
                      tooltip: saved.contains(current) ? '取消收藏' : '收藏',
                      onPressed: () {
                        setSheet(() => _toggleBookmarkPath(current));
                      },
                    ),
                    onTap: () {
                      setSheet(() => _toggleBookmarkPath(current));
                    },
                  ),
                  const Divider(height: 1),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text('快捷位置',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  for (final (label, path) in _quickPlaces)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.folder),
                      title: Text(label),
                      subtitle: Text(path,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.of(ctx).pop(path),
                    ),
                  const Divider(height: 1),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text('我的书签',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  if (saved.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                          '还没有书签：浏览到喜欢的目录后点"收藏当前目录"即可'),
                    )
                  else
                    for (final b in saved)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.bookmark_outline),
                        title: Text(b,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: '删除书签',
                          onPressed: () =>
                              setSheet(() => _removeBookmark(b)),
                        ),
                        onTap: () => Navigator.of(ctx).pop(b),
                      ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (picked == null || !mounted) return;
    _jumpTo(picked);
  }
}

/// 搜索命中项。
class _SearchHit {
  const _SearchHit({
    required this.isDir,
    required this.path,
    required this.name,
  });

  final bool isDir;
  final String path;
  final String name;
}
