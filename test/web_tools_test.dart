import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jailer/tools/url_safety.dart';
import 'package:jailer/tools/web_tools.dart';

void main() {
  group('url_safety', () {
    test('公开 URL 安全', () async {
      expect(await isSafeUrl('https://example.com'), isTrue);
      expect(await isSafeUrl('http://example.org/page'), isTrue);
    });

    test('私网 IP 拦截', () async {
      expect(await isSafeUrl('http://192.168.1.1'), isFalse);
      expect(await isSafeUrl('http://10.0.0.1'), isFalse);
      expect(await isSafeUrl('http://172.16.0.1'), isFalse);
      expect(await isSafeUrl('http://127.0.0.1'), isFalse);
    });

    test('云元数据端点永远拦截', () async {
      expect(await isSafeUrl('http://169.254.169.254/latest/meta-data'), isFalse);
      expect(await isSafeUrl('http://metadata.google.internal'), isFalse);
    });

    test('非 http/https scheme 拦截', () async {
      expect(await isSafeUrl('file:///etc/passwd'), isFalse);
      expect(await isSafeUrl('ftp://example.com'), isFalse);
    });

    test('allowPrivateUrls 开启时私网放行但元数据仍拦截', () async {
      allowPrivateUrls = true;
      try {
        expect(await isSafeUrl('http://192.168.1.1'), isTrue);
        expect(await isSafeUrl('http://169.254.169.254'), isFalse);
      } finally {
        allowPrivateUrls = false;
      }
    });

    test('isAlwaysBlockedUrl 拦截云元数据', () async {
      expect(await isAlwaysBlockedUrl('http://169.254.169.254'), isTrue);
      expect(await isAlwaysBlockedUrl('http://metadata.google.internal'), isTrue);
      expect(await isAlwaysBlockedUrl('http://example.com'), isFalse);
    });

    test('敏感查询参数检测', () {
      expect(sensitiveQueryParamName('http://x.com/?api_key=abc'), isNotNull);
      expect(sensitiveQueryParamName('http://x.com/?q=hello'), isNull);
    });
  });

  group('_htmlToText', () {
    test('提取标题和正文', () {
      final html = '<html><head><title>Test Page</title></head>'
          '<body><h1>Hello</h1><p>World <a href="http://e.com">link</a></p>'
          '<script>alert(1)</script></body></html>';
      final text = htmlToText(html);
      expect(text, contains('Test Page'));
      expect(text, contains('Hello'));
      expect(text, contains('World'));
      expect(text, contains('link'));
      expect(text, isNot(contains('alert')));
      expect(text, isNot(contains('<script>')));
    });
  });

  group('webExtractTool', () {
    test('抓取 HTML 转文本', () async {
      final client = MockClient((request) async {
        return http.Response(
          '<html><title>Example</title><body><h1>Title</h1><p>Content here</p></body></html>',
          200,
          headers: {'content-type': 'text/html'},
        );
      });
      final result = await webExtractTool(['https://github.com/example'], client: client);
      final map = jsonDecode(result) as Map;
      final results = map['results'] as List;
      expect(results.length, 1);
      expect(results.first['content'], contains('Title'));
      expect(results.first['content'], contains('Content here'));
    });

    test('私网 URL 拦截', () async {
      final result = await webExtractTool(['http://192.168.1.1/']);
      final map = jsonDecode(result) as Map;
      final results = map['results'] as List;
      expect(results.first['error'], contains('Blocked'));
    });

    test('敏感参数拦截', () async {
      final result = await webExtractTool(['http://example.com/?api_key=secret']);
      final map = jsonDecode(result) as Map;
      final results = map['results'] as List;
      expect(results.first['error'], contains('credential'));
    });
  });

  group('webSearchTool', () {
    test('DuckDuckGo 后端返回结果', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'AbstractText': 'Dart is a programming language',
            'AbstractURL': 'https://dart.dev',
            'Heading': 'Dart',
            'RelatedTopics': [
              {
                'Text': 'Flutter - UI toolkit',
                'FirstURL': 'https://flutter.dev',
              },
            ],
          }),
          200,
        );
      });
      // 替换活动后端为 mock 版（复用 DuckDuckGoBackend 但注入 client 不易，
      // 直接用 webSearchBackend 换成一个返回固定结果的测试后端）。
      final origBackend = webSearchBackend;
      webSearchBackend = _FakeBackend(client);
      try {
        final result = await webSearchTool('dart');
        final map = jsonDecode(result) as Map;
        expect(map['success'], true);
        final web = (map['data'] as Map)['web'] as List;
        expect(web, isNotEmpty);
      } finally {
        webSearchBackend = origBackend;
      }
    });
  });
}

/// 测试用固定结果后端。
class _FakeBackend implements WebSearchBackend {
  final http.Client client;
  _FakeBackend(this.client);

  @override
  bool get requiresKey => false;

  @override
  Future<List<Map<String, dynamic>>> search(String query, int limit) async {
    final uri = Uri.parse('https://api.duckduckgo.com/')
        .replace(queryParameters: {'q': query, 'format': 'json'});
    final resp = await client.get(uri);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final results = <Map<String, dynamic>>[];
    final abstractText = data['AbstractText'] as String?;
    if (abstractText != null && abstractText.isNotEmpty) {
      results.add({
        'title': data['Heading'] as String? ?? query,
        'url': data['AbstractURL'] as String? ?? '',
        'description': abstractText,
        'position': results.length + 1,
      });
    }
    final related = data['RelatedTopics'];
    if (related is List) {
      for (final topic in related) {
        if (topic is! Map<String, dynamic>) continue;
        final text = topic['Text'] as String? ?? '';
        final url = topic['FirstURL'] as String? ?? '';
        if (text.isNotEmpty && url.isNotEmpty) {
          results.add({
            'title': text.split(' - ').first,
            'url': url,
            'description': text,
            'position': results.length + 1,
          });
        }
      }
    }
    return results;
  }
}
