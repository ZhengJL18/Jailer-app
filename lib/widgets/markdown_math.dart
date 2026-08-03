import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

/// 支持 LaTeX 公式的 Markdown 渲染。
///
/// 两层处理：
/// - **块级公式** `$$...$$`（可能跨行，矩阵/方程组）：在交给 MarkdownBody
///   前先分割提取，单独用 flutter_math_fork 渲染。
/// - **行内公式** `$...$`：经 [MathInlineSyntax] 注入 MarkdownBody。
///
/// 解析失败回退显示原始 LaTeX。
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
    final segments = _splitBlockFormulas(data);
    if (segments.every((s) => !s.isFormula)) {
      // 无块级公式 → 直接渲染 markdown（含行内公式）。
      return _buildMarkdown(data);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final seg in segments)
          seg.isFormula
              ? _MathBlock(tex: seg.text, formulaColor: formulaColor)
              : _buildMarkdown(seg.text),
      ],
    );
  }

  Widget _buildMarkdown(String text) {
    return MarkdownBody(
      data: text,
      selectable: selectable,
      inlineSyntaxes: [MathInlineSyntax()],
      builders: {
        'math': MathElementBuilder(formulaColor: formulaColor),
      },
    );
  }

  /// 按 `$$...$$` 分割（跨行），返回文本段与公式段交替。
  List<_Seg> _splitBlockFormulas(String src) {
    final result = <_Seg>[];
    final regex = RegExp(r'\$\$([\s\S]+?)\$\$');
    var last = 0;
    for (final m in regex.allMatches(src)) {
      if (m.start > last) {
        result.add(_Seg(src.substring(last, m.start), false));
      }
      result.add(_Seg(m.group(1)!, true));
      last = m.end;
    }
    if (last < src.length) {
      result.add(_Seg(src.substring(last), false));
    }
    if (result.isEmpty) {
      result.add(_Seg(src, false));
    }
    return result;
  }
}

class _Seg {
  final String text;
  final bool isFormula;
  _Seg(this.text, this.isFormula);
}

/// LaTeX 规范化：LLM 常把矩阵/方程组换行写成单个 `\` + 换行，
/// 但 KaTeX 需要 `\\` 才认作换行。把孤立的 `\` + 换行补成 `\\` + 换行。
String _normalizeLatexNewlines(String tex) {
  return tex.replaceAllMapped(RegExp(r'(?<!\\)\\(?!\\)\n'), (m) => '\\\\\n');
}

/// 块级公式渲染（可能跨行）。
class _MathBlock extends StatelessWidget {
  final String tex;
  final Color? formulaColor;

  const _MathBlock({required this.tex, this.formulaColor});

  @override
  Widget build(BuildContext context) {
    final color = formulaColor ?? Theme.of(context).colorScheme.primary;
    final style = TextStyle(
      color: color,
      fontSize: 15,
      fontWeight: FontWeight.w600,
    );
    try {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Math.tex(
          _normalizeLatexNewlines(tex),
          mathStyle: MathStyle.display,
          textStyle: style,
          onErrorFallback: (_) => Text(tex, style: style),
        ),
      );
    } catch (_) {
      return Text(tex, style: style);
    }
  }
}

/// 识别 `$...$`（行内）和 `$$...$$`（块级）LaTeX 公式的 markdown inline 语法。
///
/// 用 `[\s\S]` 代替 `.` 以匹配跨行公式（矩阵/多行方程组），因为
/// md.InlineSyntax 的 pattern 强制 multiLine 但 `.` 仍不跨行。
class MathInlineSyntax extends md.InlineSyntax {
  MathInlineSyntax()
      : super(
          r'\$\$([\s\S]+?)\$\$|\$([\s\S]+?)\$',
          startCharacter: 0x24,
        );

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
          _normalizeLatexNewlines(tex),
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
