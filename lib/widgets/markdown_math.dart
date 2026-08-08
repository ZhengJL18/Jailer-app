// 全局统一 markdown 渲染组件。
//
// 内部用 printnotes 完整渲染引擎（lib/printnotes/markdown/，含 LaTeX/wiki-link/
// #tag/高亮/HTML/代码复制等扩展）。需要 provider 上下文（printnotes 的
// ThemeProvider/SettingsProvider/EditorConfigProvider），hermes 主 App 已包
// MultiProvider。字号/LaTeX 开关等由 printnotes 设置页控制。
import 'package:flutter/material.dart';

import '../printnotes/markdown/build_markdown.dart';

class MIXMarkdown extends StatelessWidget {
  final String data;
  final bool selectable;

  const MIXMarkdown({
    super.key,
    required this.data,
    this.selectable = true,
  });

  @override
  Widget build(BuildContext context) {
    return buildMarkdownWidget(
      context,
      data: data,
      fileUri: Uri.file(''),
      selectable: selectable,
      // 引擎内部是 ListView，嵌在自适应高度容器（聊天气泡）里必须 shrinkWrap，
      // 否则高度塌陷成 0 导致内容不可见。
      shrinkWrap: true,
    );
  }
}
