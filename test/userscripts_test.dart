import 'package:flutter_test/flutter_test.dart';
import 'package:jailer/tools/userscripts.dart';

void main() {
  group('userScriptsForHost', () {
    test('知乎域名有去登录脚本', () {
      final scripts = userScriptsForHost('www.zhihu.com');
      expect(scripts.any((s) => s.name.contains('知乎')), isTrue);
      expect(scripts.any((s) => s.name == '通用复制解锁'), isTrue);
    });

    test('子域名匹配', () {
      final scripts = userScriptsForHost('question.zhihu.com');
      expect(scripts.any((s) => s.name.contains('知乎')), isTrue);
    });

    test('小红书域名有脚本', () {
      final scripts = userScriptsForHost('www.xiaohongshu.com');
      expect(scripts.any((s) => s.name.contains('小红书')), isTrue);
    });

    test('无脚本域名只有通用复制解锁', () {
      final scripts = userScriptsForHost('github.com');
      expect(scripts.length, 1);
      expect(scripts.first.name, '通用复制解锁');
    });
  });

  group('isAllowedUrl', () {
    test('白名单域名允许', () {
      expect(isAllowedUrl('https://www.zhihu.com/question/123'), isTrue);
      expect(isAllowedUrl('https://www.xiaohongshu.com/explore'), isTrue);
      expect(isAllowedUrl('https://tieba.baidu.com/p/123'), isTrue);
      expect(isAllowedUrl('https://github.com/flutter/flutter'), isTrue);
      expect(isAllowedUrl('https://www.cnblogs.com/foo'), isTrue);
    });

    test('子域名允许', () {
      expect(isAllowedUrl('https://question.zhihu.com/x'), isTrue);
      expect(isAllowedUrl('https://sub.github.com/x'), isTrue);
    });

    test('任意 http/https 域名放行（私有软件不设白名单）', () {
      // 单机私有 App，翻墙/代理下任意站点都能访问（SSRF 由 url_safety 兜底）。
      expect(isAllowedUrl('https://www.douyin.com/video/123'), isTrue);
      expect(isAllowedUrl('https://www.kuaishou.com/x'), isTrue);
      expect(isAllowedUrl('https://random-site.com'), isTrue);
      expect(isAllowedUrl('http://192.168.1.1'), isTrue);
    });

    test('非 http/https 拒绝', () {
      expect(isAllowedUrl('file:///etc/passwd'), isFalse);
      expect(isAllowedUrl('ftp://github.com'), isFalse);
    });

    test('畸形 URL 拒绝', () {
      expect(isAllowedUrl('not a url'), isFalse);
    });
  });
}
