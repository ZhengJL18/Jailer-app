import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jailer/widgets/markdown_math.dart';

/// markdown_widget 引擎内部用 visibility_detector（TOC 用）会在 paint 时创建
/// 500ms 一次性 Timer；测试结束时若仍 pending 会报 "Pending timers" 错。
/// 这里 pump 一帧断言不崩后，再推进时钟让 Timer 触发结束。
Future<void> _pumpAndDrain(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
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
