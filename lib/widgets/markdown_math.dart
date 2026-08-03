import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

/// 支持 LaTeX 公式的 Markdown 渲染。
///
/// 在标准 [MarkdownBody] 基础上注入 `$...$` / `$$...$$` 行内/块级公式语法，
/// 用 flutter_math_fork 渲染，解析失败回退显示原始 LaTeX。
class HermesMarkdown extends StatelessWidget {
  final String data;
  final bool selectable;
  final Color? formulaColor;

  const HermesMarkdown({
    super.key,
    required this.data,
    this.selectable = true,
    this.formulaColor,
  });

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: data,
      selectable: selectable,
      inlineSyntaxes: [MathInlineSyntax()],
      builders: {
        'math': MathElementBuilder(formulaColor: formulaColor),
      },
    );
  }
}

/// 识别 `$...$`（行内）和 `$$...$$`（块级）LaTeX 公式的 markdown inline 语法。
class MathInlineSyntax extends md.InlineSyntax {
  MathInlineSyntax() : super(r'\$\$(.+?)\$\$|\$(.+?)\$', startCharacter: 0x24);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final isDisplay = match.group(1) != null;
    final tex = isDisplay ? match.group(1)! : match.group(2)!;
    final element = md.Element('math', [md.Text(tex)]);
    element.attributes['display'] = isDisplay ? 'true' : 'false';
    parser.addNode(element);
    return true;
  }
}

/// 把 `math` 元素渲染成 Math.tex widget。
class MathElementBuilder extends MarkdownElementBuilder {
  final Color? formulaColor;

  MathElementBuilder({this.formulaColor});

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final tex = element.children?.whereType<md.Text>().map((t) => t.text).join() ?? '';
    final isDisplay = element.attributes['display'] == 'true';
    final color = formulaColor ?? Theme.of(context).colorScheme.primary;
    final style = (parentStyle ?? preferredStyle)?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ) ??
        TextStyle(
          color: color,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        );

    try {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Math.tex(
          tex,
          mathStyle: isDisplay ? MathStyle.display : MathStyle.text,
          textStyle: style,
          onErrorFallback: (_) => Text(tex, style: style),
        ),
      );
    } catch (_) {
      return Text(tex, style: style);
    }
  }
}
