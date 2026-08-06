import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jailer/widgets/markdown_math.dart';

/// markdown_widget 引擎内部用 visibility_detector（TOC 用），paint 时持续创建
/// 500ms Timer（全局单例，dispose 时才 cancel）。测试结束若 widget 仍在树中
/// 会报 "Pending timers" 错。用 addTearDown 在每个测试结束前卸载 widget 树，
/// 让 VisibilityDetector dispose → cancel timer。
Future<void> _pumpAndDrain(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
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
    await _pumpAndDrain(tester);
    expect(tester.takeException(), isNull);
    // 关键：渲染出 Math.tex widget，而不是原始 LaTeX 文本。
    expect(find.byType(Math), findsWidgets);
    expect(find.textContaining(r'\begin{bmatrix}'), findsNothing);
  });

  testWidgets('行内矩阵渲染出 Math widget', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HermesMarkdown(data: r'矩阵 $A = \begin{bmatrix} 1 & 2 \\ 3 & 4 \end{bmatrix}$'),
      ),
    ));
    await _pumpAndDrain(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(Math), findsWidgets);
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
    await _pumpAndDrain(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(Math), findsWidgets);
    expect(find.textContaining(r'\begin{bmatrix}'), findsNothing);
  });
}
