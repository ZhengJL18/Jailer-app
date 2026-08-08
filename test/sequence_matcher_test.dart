/// 对照 CPython difflib 实测输出验证 SequenceMatcher 修复。
///
/// 基准数据来自本机 CPython 3.14.6（PYTHONIOENCODING=utf-8 实测）：
/// - 'ba'/'ab' → blocks [(0,1,1), (2,2,0)], ratio 0.5（合并条件 j1+k1）
/// - '😀'/'😁' → blocks [(1,1,0)], ratio 0.0（不同 emoji 无匹配，码点比较）
/// - 'a😀b'/'x😀y' → blocks [(1,1,1), (3,3,0)], ratio 0.3333
/// - '你好世界'/'你好朋友' → blocks [(0,0,2), (4,4,0)], ratio 0.5
/// - 'A—B'/'A--C' → opcodes [equal(0,1,0,1), replace(1,3,1,4)]
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/tools/sequence_matcher.dart';

void main() {
  group('合并条件（j1+k1）', () {
    test('ba/ab 匹配块与 Python 一致', () {
      final sm = SequenceMatcher('ba', 'ab');
      final blocks = sm.getMatchingBlocks();
      expect(blocks, [(0, 1, 1), (2, 2, 0)]);
      expect(sm.ratio(), closeTo(0.5, 1e-9));
    });
  });

  group('码点 vs UTF-16（代理对）', () {
    test('两个不同 emoji 无匹配，ratio 0', () {
      final sm = SequenceMatcher('😀', '😁');
      expect(sm.ratio(), closeTo(0.0, 1e-9));
      // 码点索引：无匹配块，只有哨兵 (1,1,0)。
      expect(sm.getMatchingBlocks(), [(1, 1, 0)]);
    });

    test('emoji 前后文本匹配，索引为码点', () {
      final sm = SequenceMatcher('a😀b', 'x😀y');
      expect(sm.getMatchingBlocks(), [(1, 1, 1), (3, 3, 0)]);
      expect(sm.ratio(), closeTo(0.3333333333333333, 1e-9));
    });

    test('中文（BMP）索引与 Python 一致', () {
      final sm = SequenceMatcher('你好世界', '你好朋友');
      expect(sm.getMatchingBlocks(), [(0, 0, 2), (4, 4, 0)]);
      expect(sm.ratio(), closeTo(0.5, 1e-9));
    });
  });

  group('opcodes', () {
    test('em dash 归一化场景 opcodes 与 Python 一致', () {
      // Python: 'A—B' vs 'A--C' → [equal(0,1,0,1), replace(1,3,1,4)]
      final sm = SequenceMatcher('A—B', 'A--C');
      final opcodes = sm.getOpcodes();
      expect(opcodes, [
        ('equal', 0, 1, 0, 1),
        ('replace', 1, 3, 1, 4),
      ]);
    });
  });

  group('autojunk', () {
    test('len(b)>=200 且 count>n//100+1 时从 b2j 删除', () {
      // count=4, n=200 → 4 > 200//100+1=3 → junk（删除，无匹配）。
      final b = 'a' * 4 + 'x' * 196;
      final a = 'a' * 4 + 'y' * 196;
      final sm = SequenceMatcher(a, b);
      // 'a' 被当 popular 删除 → 不参与匹配。
      final blocks = sm.getMatchingBlocks();
      // 只有哨兵 (200,200,0)。
      expect(blocks.last, (200, 200, 0));
    });

    test('count<=n//100+1 时不 junk（保留）', () {
      // count=3, n=200 → 3 > 3 false → 不 junk。
      final b = 'a' * 3 + 'x' * 197;
      final a = 'a' * 3 + 'y' * 197;
      final sm = SequenceMatcher(a, b);
      // 'a' 保留 → 有 3 长度匹配块。
      final blocks = sm.getMatchingBlocks();
      expect(blocks.first, (0, 0, 3));
    });

    test('autojunk 只依赖 len(b)，不依赖 len(a)', () {
      // a 很短但 b>=200 → 仍触发 autojunk。
      // Python 实测：'aaa' vs 'a'*4+'x'*196 → blocks [(0,0,3),(3,200,0)]。
      // 'a' 和 'x' 都从 b2j 删（popular），但 DP 后右端扩展仍匹配 'a'。
      final b = 'a' * 4 + 'x' * 196;
      final sm = SequenceMatcher('aaa', b);
      final blocks = sm.getMatchingBlocks();
      expect(blocks, [(0, 0, 3), (3, 200, 0)]);
    });
  });
}
