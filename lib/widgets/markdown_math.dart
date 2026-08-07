// 全局统一 markdown 渲染组件。
//
// 内部改用 printnotes 同款渲染引擎（markdown_widget 包 + lib/markdown/ 扩展层），
// 替换旧的 flutter_markdown 方案。公共 API（data/selectable/formulaColor）保持不变，
// 调用点（main.dart:1756）零改动。LaTeX 公式、代码高亮、#tag、[[wiki]]、==高亮==、
// 删除线/上下标/下划线由引擎扩展层统一支持。
import 'package:flutter/material.dart';

import '../markdown/build_markdown.dart';
import '../theme/theme_ext.dart';

class HermesMarkdown extends StatelessWidget {
  final String data;
  final bool selectable;
  final Color? formulaColor;
  /// 是否使用 LaTeX（聊天场景默认开）。
  final bool useLatex;
  /// 本地图片搜索根目录（笔记库场景传入；聊天场景默认空 = 仅相对路径解析）。
  final String? imageRoot;
  /// 编辑器字号（笔记库编辑器传入）。
  final double? editorFontSize;
  /// 链接点击覆盖（默认走 linkHandler）。
  final Future<void> Function(String url)? onLinkTap;
  /// 是否为编辑器模式（字号跟随 editorFontSize）。
  final bool inEditor;

  const HermesMarkdown({
    super.key,
    required this.data,
    this.selectable = true,
    this.formulaColor,
    this.useLatex = true,
    this.imageRoot,
    this.editorFontSize,
    this.onLinkTap,
    this.inEditor = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final opts = MarkdownRenderOptions(
      codeHighlight: Theme.of(context).brightness == Brightness.dark
          ? 'atom-one-dark'
          : 'atom-one-light',
      useLatex: useLatex,
      fontSize: editorFontSize ?? 16,
      textColor: palette.textPrimary,
      imageRoot: imageRoot,
      onLinkTap: onLinkTap,
      inEditor: inEditor,
    );
    return buildMarkdownWidget(
      context,
      data: data,
      opts: opts,
      selectable: selectable,
      // MarkdownWidget 内部是 ListView，嵌在自适应高度容器（聊天气泡/预览）里
      // 必须 shrinkWrap + 禁内层滚动，否则高度塌陷成 0 导致内容不可见。
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
    );
  }
}
