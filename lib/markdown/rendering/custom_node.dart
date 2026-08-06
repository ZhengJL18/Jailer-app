//
// 从 printnotes custom_node.dart 移植，去掉 flutter_widget_from_html_core 依赖
// （复杂 HTML 表格增强降级，普通 markdown 表格仍由 markdown_widget 原生处理）。
//

import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as m;

import 'html_support.dart';
import 'package:markdown_widget/markdown_widget.dart';

class CustomTextNode extends ElementNode {
  final String text;
  final MarkdownConfig config;
  final WidgetVisitor visitor;

  CustomTextNode(this.text, this.config, this.visitor);

  @override
  InlineSpan build() => super.build();

  @override
  void onAccepted(SpanNode parent) {
    final textStyle = config.p.textStyle.merge(parentStyle);
    children.clear();
    if (!text.contains(htmlRep)) {
      accept(TextNode(text: text, style: textStyle));
      return;
    }

    // 文本内嵌 HTML → 转为 span 节点流。
    final spans = parseHtml(
      m.Text(text),
      visitor: WidgetVisitor(
        config: visitor.config,
        generators: visitor.generators,
        richTextBuilder: visitor.richTextBuilder,
      ),
      parentStyle: parentStyle,
    );
    for (final element in spans) {
      accept(element);
    }
  }
}
