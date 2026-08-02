// 字符串拼接风格忠实 Python difflib 源码（f-string 直译）。
// ignore_for_file: prefer_interpolation_to_compose_strings

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

  /// `difflib.get_grouped_opcodes(n)`：把 opcodes 分成适合 diff 展示的组。
  /// 组间用足够的上下文相等区间分隔；组内首尾的相等区间按 `n` 收缩。
  List<List<MatchOpcode>> getGroupedOpcodes(int n) {
    var codes = getOpcodes();
    if (codes.isEmpty) {
      codes = [('equal', 0, 1, 0, 1)];
    }
    if (codes.first.$1 == 'equal') {
      final (tag, i1, i2, j1, j2) = codes.first;
      codes[0] = (
        tag,
        i1 > i2 - n ? i1 : i2 - n,
        i2,
        j1 > j2 - n ? j1 : j2 - n,
        j2,
      );
    }
    if (codes.last.$1 == 'equal') {
      final (tag, i1, i2, j1, j2) = codes.last;
      codes[codes.length - 1] = (
        tag,
        i1,
        i2 < i1 + n ? i2 : i1 + n,
        j1,
        j2 < j1 + n ? j2 : j1 + n,
      );
    }
    final nn = n + n;
    final groups = <List<MatchOpcode>>[];
    var group = <MatchOpcode>[];
    for (final code in codes) {
      var (tag, i1, i2, j1, j2) = code;
      if (tag == 'equal' && i2 - i1 > nn) {
        group.add((
          tag,
          i1,
          i2 < i1 + n ? i2 : i1 + n,
          j1,
          j2 < j1 + n ? j2 : j1 + n,
        ));
        groups.add(group);
        group = <MatchOpcode>[];
        i1 = i2 - n > i1 ? i2 - n : i1; // max(i1, i2-n)
        j1 = j2 - n > j1 ? j2 - n : j1; // max(j1, j2-n)
        group.add((tag, i1, i2, j1, j2));
      } else {
        group.add(code);
      }
    }
    if (group.isNotEmpty &&
        !(group.length == 1 && group.first.$1 == 'equal')) {
      groups.add(group);
    }
    return groups;
  }
}

/// `difflib._format_range_unified`：`@@` 头里的范围格式。
String formatRangeUnified(int start, int stop) {
  final beginning = start + 1; // 行号从 1 开始。
  final length = stop - start;
  if (length == 1) {
    return '$beginning';
  }
  var beg = beginning;
  if (length == 0) {
    beg -= 1; // 空范围从范围前一行开始。
  }
  return '$beg,$length';
}

/// `difflib.unified_diff`：生成统一 diff 行。
///
/// [a]/[b] 是带行尾（keepends）的行列表。默认 `n=3`、`lineterm='\n'`。
/// 返回的行含行尾。
List<String> unifiedDiff(
  List<String> a,
  List<String> b, {
  String fromfile = '',
  String tofile = '',
  String fromfiledate = '',
  String tofiledate = '',
  int n = 3,
  String lineterm = '\n',
}) {
  final result = <String>[];
  var started = false;
  // difflib 对 keepends 行列表直接用 SequenceMatcher(None, a, b)，以整行（含
  // 行尾）为元素比较。SequenceMatcherLines 提供基于整行列表的序列比对。
  final lineMatcher = SequenceMatcherLines(a, b);
  for (final group in lineMatcher.getGroupedOpcodes(n)) {
    if (!started) {
      started = true;
      final fromdate = fromfiledate.isNotEmpty ? '\t$fromfiledate' : '';
      final todate = tofiledate.isNotEmpty ? '\t$tofiledate' : '';
      result.add('--- $fromfile$fromdate$lineterm');
      result.add('+++ $tofile$todate$lineterm');
    }
    final first = group.first;
    final last = group.last;
    final file1Range = formatRangeUnified(first.$2, last.$3);
    final file2Range = formatRangeUnified(first.$4, last.$5);
    result.add('@@ -$file1Range +$file2Range @@$lineterm');
    for (final (tag, i1, i2, j1, j2) in group) {
      if (tag == 'equal') {
        for (var k = i1; k < i2; k++) {
          result.add(' ' + a[k]);
        }
        continue;
      }
      if (tag == 'replace' || tag == 'delete') {
        for (var k = i1; k < i2; k++) {
          result.add('-' + a[k]);
        }
      }
      if (tag == 'replace' || tag == 'insert') {
        for (var k = j1; k < j2; k++) {
          result.add('+' + b[k]);
        }
      }
    }
  }
  return result;
}

/// 基于整行列表的 SequenceMatcher（difflib 以行元素做序列匹配）。
///
/// difflib 的 `unified_diff(a, b)` 中 `a`/`b` 是行列表，SequenceMatcher 对
/// **元素（整行）** 做序列比对，而非拼接后的字符。此适配让 opcodes 的
/// i1/i2/j1/j2 索引直接对应行索引。
class SequenceMatcherLines {
  final List<String> a;
  final List<String> b;
  final List<(int, int, int)> _blocks = [];

  SequenceMatcherLines(this.a, this.b) {
    _blocks.addAll(_matchingBlocks());
  }

  // 元素级最长公共子序列（O(n*m)，difflib 的 j2len 动态规划，逐元素而非逐字符）。
  List<(int, int, int)> _matchingBlocks() {
    final la = a.length;
    final lb = b.length;
    final queue = <(int, int, int, int)>[(0, la, 0, lb)];
    final matchingBlocks = <(int, int, int)>[];
    while (queue.isNotEmpty) {
      final (alo, ahi, blo, bhi) = queue.removeLast();
      var besti = alo;
      var bestj = blo;
      var bestsize = 0;
      var j2len = <int, int>{};
      for (var i = alo; i < ahi; i++) {
        final newj2len = <int, int>{};
        for (var j = blo; j < bhi; j++) {
          if (a[i] == b[j]) {
            final k = (j2len[j - 1] ?? 0) + 1;
            newj2len[j] = k;
            if (k > bestsize) {
              besti = i - k + 1;
              bestj = j - k + 1;
              bestsize = k;
            }
          }
        }
        j2len = newj2len;
      }
      if (bestsize != 0) {
        matchingBlocks.add((besti, bestj, bestsize));
        if (alo < besti && blo < bestj) {
          queue.add((alo, besti, blo, bestj));
        }
        if (besti + bestsize < ahi && bestj + bestsize < bhi) {
          queue.add((besti + bestsize, ahi, bestj + bestsize, bhi));
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
    final nonAdjacent = <(int, int, int)>[];
    for (final (i2, j2, k2) in matchingBlocks) {
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

  /// 从匹配块派生编辑操作。
  List<MatchOpcode> getOpcodes() {
    var i = 0;
    var j = 0;
    final opcodes = <MatchOpcode>[];
    for (final (ai, bj, size) in _blocks) {
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

  /// `difflib.get_grouped_opcodes`，语义同 [SequenceMatcher.getGroupedOpcodes]。
  List<List<MatchOpcode>> getGroupedOpcodes(int n) {
    var codes = getOpcodes();
    if (codes.isEmpty) {
      codes = [('equal', 0, 1, 0, 1)];
    }
    if (codes.first.$1 == 'equal') {
      final (tag, i1, i2, j1, j2) = codes.first;
      codes[0] = (
        tag,
        i1 > i2 - n ? i1 : i2 - n,
        i2,
        j1 > j2 - n ? j1 : j2 - n,
        j2,
      );
    }
    if (codes.last.$1 == 'equal') {
      final (tag, i1, i2, j1, j2) = codes.last;
      codes[codes.length - 1] = (
        tag,
        i1,
        i2 < i1 + n ? i2 : i1 + n,
        j1,
        j2 < j1 + n ? j2 : j1 + n,
      );
    }
    final nn = n + n;
    final groups = <List<MatchOpcode>>[];
    var group = <MatchOpcode>[];
    for (final code in codes) {
      final (tag, i1, i2, j1, j2) = code;
      if (tag == 'equal' && i2 - i1 > nn) {
        group.add((
          tag,
          i1,
          i2 < i1 + n ? i2 : i1 + n,
          j1,
          j2 < j1 + n ? j2 : j1 + n,
        ));
        groups.add(group);
        group = <MatchOpcode>[];
        final ni1 = i2 - n > i1 ? i2 - n : i1;
        final nj1 = j2 - n > j1 ? j2 - n : j1;
        group.add((tag, ni1, i2, nj1, j2));
      } else {
        group.add(code);
      }
    }
    if (group.isNotEmpty &&
        !(group.length == 1 && group.first.$1 == 'equal')) {
      groups.add(group);
    }
    return groups;
  }
}
