import 'package:flutter_test/flutter_test.dart';
import 'package:mix/agent/error_classifier.dart';
import 'package:mix/agent/retry_utils.dart';
import 'package:mix/llm/openai_llm.dart';

void main() {
  group('classifyApiError', () {
    test('401 认证失败不可重试', () {
      final e = LlmException('auth failed', statusCode: 401);
      final c = classifyApiError(e);
      expect(c.retryable, isFalse);
      expect(c.isAuth, isTrue);
    });

    test('429 限流可重试', () {
      final e = LlmException('rate limit', statusCode: 429);
      final c = classifyApiError(e);
      expect(c.retryable, isTrue);
      expect(c.reason, FailoverReason.rateLimit);
    });

    test('413 应压缩', () {
      final e = LlmException('too large', statusCode: 413);
      final c = classifyApiError(e);
      expect(c.retryable, isTrue);
      expect(c.shouldCompress, isTrue);
    });

    test('500 服务端可重试', () {
      final e = LlmException('server error', statusCode: 500);
      final c = classifyApiError(e);
      expect(c.retryable, isTrue);
    });

    test('400 客户端错误不可重试', () {
      final e = LlmException('bad request', statusCode: 400);
      final c = classifyApiError(e);
      expect(c.retryable, isFalse);
    });

    test('计费消息识别', () {
      final e = LlmException('insufficient credits', statusCode: 403);
      final c = classifyApiError(e);
      expect(c.reason, FailoverReason.billing);
    });
  });

  group('extractStatusCode', () {
    test('从 LlmException 提取', () {
      final e = LlmException('x', statusCode: 429);
      expect(extractStatusCode(e), 429);
    });
  });

  group('jitteredBackoff', () {
    test('递增退避', () {
      final d1 = jitteredBackoff(1, baseDelay: 2, maxDelay: 10);
      final d2 = jitteredBackoff(2, baseDelay: 2, maxDelay: 10);
      // attempt 2 应比 attempt 1 基准更大（2*2=4 vs 2）。
      expect(d2, greaterThan(d1));
    });

    test('上限封顶', () {
      final d = jitteredBackoff(10, baseDelay: 2, maxDelay: 10);
      expect(d, lessThan(16)); // 10 + jitter(≤5)
    });

    test('非负', () {
      final d = jitteredBackoff(1, baseDelay: 1, maxDelay: 5);
      expect(d, greaterThanOrEqualTo(0));
    });
  });
}
