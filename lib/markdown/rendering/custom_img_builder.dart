// 从 printnotes custom_img_builder.dart 移植，去掉 provider 耦合：
// - EditorConfigProvider.fontSize → 注入 fontSize 参数
// - SettingsProvider.mainDir 全盘搜图 → 注入 imageRoot（笔记根目录）内查找
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// 本地图片渲染器：http 图走网络，本地图按「相对笔记路径 → imageRoot 内按文件名 → 绝对路径」三级解析。
class CustomImgBuilder extends StatelessWidget {
  final String url;
  final Uri fileUri;
  final Map<String, String> attributes;
  final String imageRoot;
  final double fontSize;

  const CustomImgBuilder(
    this.url,
    this.fileUri,
    this.attributes, {
    super.key,
    required this.imageRoot,
    this.fontSize = 16,
  });

  @override
  Widget build(BuildContext context) {
    // 相对笔记文件目录找图（url 以 ./ 开头或直接相对名）。
    File _relativeFile() {
      final base = p.dirname(fileUri.toFilePath());
      final clean = url.startsWith('.$p.separator')
          ? url.substring(2)
          : url;
      return File(p.join(base, clean));
    }

    // 在 imageRoot 内按文件名递归查找（不做全盘扫，限定笔记根目录）。
    Future<File?> _findInRoot() async {
      final root = Directory(imageRoot);
      if (!await root.exists()) return null;
      await for (final entity in root.list(recursive: true)) {
        if (entity is File && p.basename(entity.path) == url) {
          return entity;
        }
      }
      return null;
    }

    Widget errorMessage(String text) => Padding(
          padding: const EdgeInsets.all(8.0),
          child: RichText(
            softWrap: true,
            maxLines: 3,
            text: TextSpan(
              style: TextStyle(fontSize: fontSize),
              children: [
                WidgetSpan(
                  child: Tooltip(
                    triggerMode: TooltipTriggerMode.tap,
                    showDuration: const Duration(seconds: 5),
                    enableTapToDismiss: true,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .error
                          .withValues(alpha: 0.5),
                    ),
                    message: text,
                    textStyle: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface),
                    child: Icon(
                      Icons.broken_image,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                TextSpan(
                  text: ' ${attributes['alt'] ?? ''}',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface),
                ),
              ],
            ),
          ),
        );

    if (url.startsWith('http')) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Center(
            child: CircularProgressIndicator(
              value: loadingProgress.expectedTotalBytes != null
                  ? loadingProgress.cumulativeBytesLoaded /
                      loadingProgress.expectedTotalBytes!
                  : null,
            ),
          );
        },
        errorBuilder: (context, error, stackTrace) =>
            errorMessage('Image could not be loaded'),
      );
    }

    return FutureBuilder<File?>(
      future: _resolveLocalFile(_relativeFile, _findInRoot),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final f = snapshot.data;
        return Image.file(
          f ?? File(''),
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => errorMessage(
              'Incorrect path or file type, check if url is correct'),
        );
      },
    );
  }

  Future<File?> _resolveLocalFile(
    File Function() relative,
    Future<File?> Function() findInRoot,
  ) async {
    final rel = relative();
    if (rel.existsSync()) return rel;
    final inRoot = await findInRoot();
    if (inRoot != null) return inRoot;
    final full = File(url);
    if (full.existsSync()) return full;
    return null;
  }
}
