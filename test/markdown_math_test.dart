import 'package:flutter/material.dart';
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

Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
}

void main() {
  testWidgets('HermesMarkdown 渲染行内公式不崩', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HermesMarkdown(data: r'勾股定理 $a^2 + b^2 = c^2$ 成立'),
      ),
    ));
    await _pump(tester);
    expect(tester.takeException(), isNull);
    await _teardown(tester);
  });

  testWidgets('HermesMarkdown 渲染块级公式不崩', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HermesMarkdown(data: r'公式：$$\int_0^1 x^2 dx$$'),
      ),
    ));
    await _pump(tester);
    expect(tester.takeException(), isNull);
    await _teardown(tester);
  });

  testWidgets('HermesMarkdown 渲染纯文本不崩', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HermesMarkdown(data: '你好，这是普通回复。\n\n- 列表项一\n- 列表项二'),
      ),
    ));
    await _pump(tester);
    expect(tester.takeException(), isNull);
    await _teardown(tester);
  });
}
