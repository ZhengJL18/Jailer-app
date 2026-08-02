/// Python `difflib.SequenceMatcher` 的 Dart 复刻（像素级复刻）。
///
/// fuzzy_match.py 依赖 `SequenceMatcher(None, a, b)`：
/// - `ratio()`（block_anchor / context_aware 相似度阈值）
/// - `get_opcodes()`（`_preserve_unicode_in_replacement` 的编辑区间）
///
/// 忠实实现 Python 语义：
/// - `_chain_b` 构建 b2j（字符→位置表）
/// - **autojunk**：len(a)≥200 且 len(b)≥200 时，b 中出现 >len(b)/100 次的字符
///   视为 popular junk（`bjunk`），扩展匹配时跳过
/// - `find_longest_match` 用 j2len 动态规划（等价 difflib）
/// - `get_matching_blocks` 排序 + 合并相邻 + 哨兵；`get_opcodes` 派生编辑操作
library;

/// 编辑操作：`(tag, i1, i2, j1, j2)`，tag ∈ equal/replace/delete/insert。
typedef MatchOpcode = (String, int, int, int, int);
typedef Block3 = (int, int, int);

class SequenceMatcher {
  final String a;
  final String b;
  final Map<int, List<int>> _b2j = {};
  final Set<int> _bjunk = {};

  SequenceMatcher(this.a, this.b) {
    _chainB();
  }

  void _chainB() {
    for (var j = 0; j < b.length; j++) {
      _b2j.putIfAbsent(b.codeUnitAt(j), () => []).add(j);
    }
    // autojunk（difflib 默认开启）：大字符串时把"流行"字符当 junk。
    if (a.length >= 200 && b.length >= 200) {
      final n = b.length;
      final count = <int, int>{};
      for (var j = 0; j < n; j++) {
        final c = b.codeUnitAt(j);
        count[c] = (count[c] ?? 0) + 1;
      }
      final cutoff = n / 100;
      count.forEach((k, v) {
        if (v > cutoff) {
          _bjunk.add(k);
        }
      });
    }
  }

  bool _isBunk(int c) => _bjunk.contains(c);

  /// 在 [alo, ahi)×[blo, bhi) 找最长公共子串，返回 (besti, bestj, bestsize)。
  (int, int, int) _findLongestMatch(int alo, int ahi, int blo, int bhi) {
    var besti = alo;
    var bestj = blo;
    var bestsize = 0;
    var j2len = <int, int>{};
    for (var i = alo; i < ahi; i++) {
      final positions = _b2j[a.codeUnitAt(i)] ?? const [];
      final newj2len = <int, int>{};
      for (final j in positions) {
        if (j < blo) {
          continue;
        }
        if (j >= bhi) {
          break;
        }
        final k = (j2len[j - 1] ?? 0) + 1;
        newj2len[j] = k;
        if (k > bestsize) {
          besti = i - k + 1;
          bestj = j - k + 1;
          bestsize = k;
        }
      }
      j2len = newj2len;
    }

    // 两端用非 junk 元素扩展 best。
    while (besti > alo &&
        bestj > blo &&
        !_isBunk(b.codeUnitAt(bestj - 1)) &&
        a.codeUnitAt(besti - 1) == b.codeUnitAt(bestj - 1)) {
      besti--;
      bestj--;
      bestsize++;
    }
    while (besti + bestsize < ahi &&
        bestj + bestsize < bhi &&
        !_isBunk(b.codeUnitAt(bestj + bestsize)) &&
        a.codeUnitAt(besti + bestsize) == b.codeUnitAt(bestj + bestsize)) {
      bestsize++;
    }
    return (besti, bestj, bestsize);
  }

  /// 返回匹配块列表（含哨兵 `(len(a), len(b), 0)`），已排序并合并相邻。
  List<Block3> getMatchingBlocks() {
    final la = a.length;
    final lb = b.length;
    final queue = <(int, int, int, int)>[(0, la, 0, lb)];
    final matchingBlocks = <Block3>[];
    while (queue.isNotEmpty) {
      final (alo, ahi, blo, bhi) = queue.removeLast();
      final (i, j, k) = _findLongestMatch(alo, ahi, blo, bhi);
      if (k != 0) {
        matchingBlocks.add((i, j, k));
        if (alo < i && blo < j) {
          queue.add((alo, i, blo, j));
        }
        if (i + k < ahi && j + k < bhi) {
          queue.add((i + k, ahi, j + k, bhi));
        }
      }
    }
    matchingBlocks.sort((x, y) {
      final c = x.$1.compareTo(y.$1);
      return c != 0 ? c : x.$2.compareTo(y.$2);
    });

    var i1 = 0;
    var j1 = 0;
    var k1 = 0;
    final nonAdjacent = <Block3>[];
    for (final (i2, j2, k2) in matchingBlocks) {
      // difflib 原文：`j1 + k2 == j2`（k1 与 k2 相邻时相等，忠实保留）
      if (i1 + k1 == i2 && j1 + k2 == j2) {
        k1 += k2;
      } else {
        if (k1 != 0) {
          nonAdjacent.add((i1, j1, k1));
        }
        i1 = i2;
        j1 = j2;
        k1 = k2;
      }
    }
    if (k1 != 0) {
      nonAdjacent.add((i1, j1, k1));
    }
    nonAdjacent.add((la, lb, 0));
    return nonAdjacent;
  }

  /// 返回编辑操作序列 `(tag, i1, i2, j1, j2)`。
  List<MatchOpcode> getOpcodes() {
    final blocks = getMatchingBlocks();
    var i = 0;
    var j = 0;
    final opcodes = <MatchOpcode>[];
    for (final (ai, bj, size) in blocks) {
      String tag;
      if (i < ai && j < bj) {
        tag = 'replace';
      } else if (i < ai) {
        tag = 'delete';
      } else if (j < bj) {
        tag = 'insert';
      } else {
        tag = '';
      }
      if (tag != '') {
        opcodes.add((tag, i, ai, j, bj));
      }
      i = ai + size;
      j = bj + size;
      if (size > 0) {
        opcodes.add(('equal', ai, i, bj, j));
      }
    }
    return opcodes;
  }

  /// `difflib.ratio()`：`2 * M / (len(a) + len(b))`，空串对返回 1.0。
  double ratio() {
    var matches = 0;
    for (final (_, _, k) in getMatchingBlocks()) {
      matches += k;
    }
    final total = a.length + b.length;
    if (total == 0) {
      return 1.0;
    }
    return 2.0 * matches / total;
  }
}
