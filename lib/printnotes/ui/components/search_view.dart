import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:mix/printnotes/providers/settings_provider.dart';
import 'package:mix/printnotes/providers/navigation_provider.dart';
import 'package:mix/printnotes/utils/storage_system.dart';

class SearchView extends StatefulWidget {
  const SearchView({
    super.key,
    required this.searchQuery,
  });

  final String searchQuery;

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  // 缓存当前查询的 future，避免每次 rebuild 全库重扫。
  String _cacheQuery = '';
  Future<List<FileSystemEntity>>? _future;

  @override
  void initState() {
    super.initState();
    _cacheQuery = widget.searchQuery;
    _future = _buildFuture(widget.searchQuery);
  }

  @override
  void didUpdateWidget(SearchView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.searchQuery != _cacheQuery) {
      _cacheQuery = widget.searchQuery;
      _future = _buildFuture(widget.searchQuery);
    }
  }

  Future<List<FileSystemEntity>> _buildFuture(String query) {
    final q = query.trim();
    // 空查询不扫描：直接返回空列表。
    if (q.isEmpty) return Future.value(const <FileSystemEntity>[]);
    return StorageSystem(context).searchItems(q);
  }

  /// 只读文件头片段，避免整读大笔记阻塞 UI；失败返回空串。
  String _readHeadSnippet(File file, int max) {
    try {
      final raf = file.openSync();
      try {
        final bytes = raf.readSync(max);
        // 必须用 utf8.decode，否则中文按字节 fromCharCodes 变乱码、subtitle
        // 永远匹配不上查询词。
        return utf8.decode(bytes, allowMalformed: true);
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return '';
    }
  }

  Widget? _buildSubtitle(BuildContext context, File item) {
    final relativePath = path.relative(item.path,
        from: context.watch<SettingsProvider>().mainDir);
    // 读取失败（文件被删/不可读）→ 只显示路径，不崩溃。
    final text = _readHeadSnippet(item, 4096).replaceAll('\n', ' ');
    if (text.isEmpty) return Text('/$relativePath');

    int maxChar = 40;

    String textLC = text.toLowerCase();
    String searchQueryLC = widget.searchQuery.trim().toLowerCase();

    // if search result empty, return empty text subtitle
    if (searchQueryLC.isEmpty || !textLC.contains(searchQueryLC)) {
      return Text('/$relativePath');
    }

    final int startIndex = textLC.indexOf(searchQueryLC);
    // if search query not found, display first few characters based on maxChar
    // of file text followed by ellipsis
    if (startIndex == -1) {
      return Text(
          '${text.substring(0, text.length < maxChar ? text.length : maxChar).trim()}...');
    }

    final int endIndex = startIndex + widget.searchQuery.trim().length;
    final int previewStart = startIndex > 25 ? startIndex - 25 : 0;
    final int previewEnd =
        text.length > endIndex + 25 ? endIndex + 25 : text.length;
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: DefaultTextStyle.of(context).style,
        children: [
          // if search query not at start of text, add ellipsis in the front
          if (previewStart > 0) const TextSpan(text: '...'),
          TextSpan(text: text.substring(previewStart, startIndex)),
          // Bold the text you have entered
          TextSpan(
            text: text.substring(startIndex, endIndex),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          // display the rest of the result with ellipsis if too long
          TextSpan(text: text.substring(endIndex, previewEnd)),
          if (previewEnd < text.length) const TextSpan(text: '...'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final future = _future;
    if (future == null) return const SizedBox.shrink();

    return FutureBuilder<List<FileSystemEntity>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final items = snapshot.data ?? const <FileSystemEntity>[];
        if (items.isEmpty) {
          return Center(
            child: Text(
              widget.searchQuery.trim().isEmpty
                  ? '输入关键词搜索笔记'
                  : '没有找到匹配的笔记',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.outline),
            ),
          );
        }
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];

            return ListTile(
              leading: Icon(
                Icons.insert_drive_file,
                color: Theme.of(context).colorScheme.secondary,
              ),
              title: Text(path.basename(item.path)),
              subtitle: _buildSubtitle(context, File(item.path)),
              onTap: () {
                // Should never be a folder but it is just a backup check unless I messed something up
                if (item is File) {
                  context
                      .read<NavigationProvider>()
                      .routeItemToPage(context, item.uri);
                }
              },
            );
          },
        );
      },
    );
  }
}
