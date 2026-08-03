import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jailer/widgets/markdown_math.dart';

void main() {
  testWidgets('HermesMarkdown 渲染行内公式不崩', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HermesMarkdown(data: r'勾股定理 $a^2 + b^2 = c^2$ 成立'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('HermesMarkdown 渲染块级公式不崩', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HermesMarkdown(data: r'公式：$$\int_0^1 x^2 dx$$'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('HermesMarkdown 渲染纯文本不崩', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HermesMarkdown(data: '你好，这是普通回复。\n\n- 列表项一\n- 列表项二'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
