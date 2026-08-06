import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jailer/widgets/markdown_math.dart';

/// markdown_widget 引擎内部用 visibility_detector（TOC 用），paint 时持续创建
/// 500ms Timer（全局单例，dispose 时才 cancel）。测试结束若 widget 仍在树中
/// 会报 "Pending timers" 错。这里 pump 一帧断言不崩后，卸载 widget 树让
/// VisibilityDetector dispose → cancel timer。
Future<void> _pumpAndDrain(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
}

void main() {
  testWidgets('HermesMarkdown 渲染行内公式不崩', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HermesMarkdown(data: r'勾股定理 $a^2 + b^2 = c^2$ 成立'),
      ),
    ));
    await _pumpAndDrain(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HermesMarkdown 渲染块级公式不崩', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HermesMarkdown(data: r'公式：$$\int_0^1 x^2 dx$$'),
      ),
    ));
    await _pumpAndDrain(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HermesMarkdown 渲染纯文本不崩', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HermesMarkdown(data: '你好，这是普通回复。\n\n- 列表项一\n- 列表项二'),
      ),
    ));
    await _pumpAndDrain(tester);
    expect(tester.takeException(), isNull);
  });
}
