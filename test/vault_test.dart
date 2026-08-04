import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jailer/services/vault_service.dart';

void main() {
  group('vault 加密往返', () {
    test('加密→解密恢复原数据', () {
      final payload = {
        'state_db': 'base64data',
        'files': {'memories/user.md': '你好', 'skills/test/SKILL.md': '# test'},
        'backed_up_at': '2026-08-04T00:00:00',
      };
      final encrypted = encryptPayload(payload, 'my-secret-key');
      final decrypted = decryptPayload(encrypted, 'my-secret-key');
      expect(decrypted['state_db'], 'base64data');
      expect(decrypted['files']['memories/user.md'], '你好');
      expect(decrypted['backed_up_at'], '2026-08-04T00:00:00');
    });

    test('相同数据两次加密产生不同密文（随机 IV）', () {
      final payload = {'state_db': 'x', 'files': <String, String>{}};
      final a = encryptPayload(payload, 'key');
      final b = encryptPayload(payload, 'key');
      expect(base64Encode(a), isNot(base64Encode(b)));
    });

    test('错误密钥解密失败', () {
      final payload = {'state_db': 'x'};
      final encrypted = encryptPayload(payload, 'correct-key');
      // 错误密钥解密产生乱码 JSON，应抛异常或返回非预期。
      expect(() => decryptPayload(encrypted, 'wrong-key'),
          throwsA(anything));
    });
  });
}
