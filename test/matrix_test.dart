import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jailer/widgets/markdown_math.dart';

/// markdown_widget 引擎内部用 visibility_detector（TOC 用），paint 时创建
/// 全局 500ms 一次性 Timer（首个可见块触发后清空 _updates 并置 null）。
/// 测试必须：1) 推进时钟让 timer 触发；2) 测试体内卸载 widget 树让
/// VisibilityDetector detach（否则框架 teardown 的 runApp 会再触发 paint）。
Future<void> _pump(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// 测试体末尾卸载 widget 树，让 VisibilityDetector detach，
/// 避免框架 teardown 时再触发 paint 创建 timer。
Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
}

void main() {
  testWidgets('跨行矩阵渲染出 Math widget（非原文 fallback）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HermesMarkdown(data: r'''
公式：
$$
\begin{bmatrix}
1 & 2 \\
3 & 4
\end{bmatrix}
$$
'''),
      ),
    ));
    await _pump(tester);
    expect(tester.takeException(), isNull);
    // 关键：渲染出 Math.tex widget，而不是原始 LaTeX 文本。
    expect(find.byType(Math), findsWidgets);
    expect(find.textContaining(r'\begin{bmatrix}'), findsNothing);
    await _teardown(tester);
  });

  testWidgets('行内矩阵渲染出 Math widget', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HermesMarkdown(data: r'矩阵 $A = \begin{bmatrix} 1 & 2 \\ 3 & 4 \end{bmatrix}$'),
      ),
    ));
    await _pump(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(Math), findsWidgets);
    await _teardown(tester);
  });

  testWidgets('LLM 单反斜杠换行矩阵也能渲染（规范化）', (tester) async {
    // 有些 LLM 输出单反斜杠 + 换行，规范化成 \\ 后 KaTeX 可解析。
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HermesMarkdown(data: r'''
$$
\begin{bmatrix}
1 & 2 \
3 & 4
\end{bmatrix}
$$
'''),
      ),
    ));
    await _pump(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(Math), findsWidgets);
    expect(find.textContaining(r'\begin{bmatrix}'), findsNothing);
    await _teardown(tester);
  });
}
