import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

void main() {
  testWidgets('MarkdownBody 渲染中文回复不崩', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MarkdownBody(
          data: '你好！😊\n\n### 📚 按课件目录给你做专题复习\n比如你现在学到「第三章」，我可以帮你：\n- 函数单调性\n- 指数对数运算\n\n**加粗** *斜体*',
          selectable: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
