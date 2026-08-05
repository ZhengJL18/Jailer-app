/// 课堂笔记主屏。
///
/// 录音 → 转写（带说话人分离）→ DeepSeek 总结 → 本地笔记 + Markdown 导出。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../lecture/deepseek_notes.dart';
import '../lecture/lecture_db.dart';
import '../lecture/model_manager.dart';
import '../lecture/models.dart';
import '../lecture/recording_service.dart';
import '../lecture/transcription_engine.dart';

/// 会话详情页路由参数。
class SessionDetailArgs {
  SessionDetailArgs(this.session);
  final LectureSession session;
}

class LectureScreen extends StatefulWidget {
  const LectureScreen({super.key});

  @override
  State<LectureScreen> createState() => _LectureScreenState();
}

class _LectureScreenState extends State<LectureScreen> {
  final RecordingService _recorder = RecordingService();
  final LectureDb _db = LectureDb.instance;

  bool _isRecording = false;
  Timer? _recordTimer;
  int _recordSeconds = 0;
  String? _recordingPath;

  List<LectureSession> _sessions = [];
  String _hotwords = '';

  @override
  void initState() {
    super.initState();
    _refreshSessions();
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshSessions() async {
    final list = await _db.listSessions();
    if (!mounted) return;
    setState(() => _sessions = list);
  }

  Future<void> _toggleRecord() async {
    if (_isRecording) {
      await _stopRecord();
    } else {
      await _startRecord();
    }
  }

  Future<void> _startRecord() async {
    try {
      final path = await _recorder.start();
      if (path.isEmpty) return;
      setState(() {
        _isRecording = true;
        _recordingPath = path;
        _recordSeconds = 0;
      });
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordSeconds++);
      });
    } catch (e) {
      _snack('录音失败：$e');
    }
  }

  Future<void> _stopRecord() async {
    _recordTimer?.cancel();
    final path = await _recorder.stop();
    setState(() => _isRecording = false);
    if (path == null || path.isEmpty || !await File(path).exists()) {
      _snack('未获得录音文件');
      return;
    }
    final session = LectureSession(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: _sessionTitle(path),
      audioPath: path,
      createdAt: DateTime.now(),
      status: LectureStatus.recorded,
    );
    await _db.saveSession(session: session);
    _refreshSessions();
    _openDetail(session);
  }

  String _sessionTitle(String path) {
    final base = p.basenameWithoutExtension(path);
    final date = DateTime.now();
    return '录音 ${date.month}月${date.day}日 ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }

  void _openDetail(LectureSession session) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SessionDetailScreen(
          session: session,
          hotwords: _hotwords,
        ),
      ),
    ).then((_) => _refreshSessions());
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _showDeepSeekConfig() async {
    final cfg = await deepSeekConfig();
    final keyCtrl = TextEditingController(text: cfg.key);
    final modelCtrl = TextEditingController(text: cfg.model);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('DeepSeek 配置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: keyCtrl,
              decoration: const InputDecoration(labelText: 'API Key'),
              obscureText: true,
            ),
            TextField(
              controller: modelCtrl,
              decoration: const InputDecoration(
                labelText: '模型（默认 deepseek-chat）',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true) {
      await saveDeepSeekConfig(key: keyCtrl.text, model: modelCtrl.text);
      _snack('DeepSeek 配置已保存');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('课堂笔记'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'DeepSeek 配置',
            onPressed: _showDeepSeekConfig,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildRecordCard(context),
          const Divider(height: 1),
          Expanded(child: _buildSessionList()),
        ],
      ),
    );
  }

  Widget _buildRecordCard(BuildContext context) {
    final mm = (_recordSeconds ~/ 60).toString().padLeft(2, '0');
    final ss = (_recordSeconds % 60).toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isRecording ? '正在录音  $mm:$ss' : '开始一节新课堂',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(
                    labelText: '热词（逗号分隔，如：麻黄汤,小青龙汤）',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => _hotwords = v,
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          _buildRecordButton(),
        ],
      ),
    );
  }

  Widget _buildRecordButton() {
    return IconButton.filled(
      iconSize: 48,
      onPressed: _toggleRecord,
      icon: Icon(
        _isRecording ? Icons.stop : Icons.fiber_manual_record,
        color: _isRecording ? Colors.white : Colors.redAccent,
      ),
      style: IconButton.styleFrom(
        backgroundColor: _isRecording ? Colors.redAccent : null,
        padding: const EdgeInsets.all(12),
      ),
      tooltip: _isRecording ? '停止录音' : '开始录音',
    );
  }

  Widget _buildSessionList() {
    if (_sessions.isEmpty) {
      return const Center(child: Text('还没有录音记录'));
    }
    return ListView.builder(
      itemCount: _sessions.length,
      itemBuilder: (context, i) {
        final s = _sessions[i];
        return ListTile(
          leading: Icon(
            s.status == LectureStatus.done
                ? Icons.article
                : s.status == LectureStatus.transcribing
                    ? Icons.autorenew
                    : Icons.mic,
          ),
          title: Text(s.title),
          subtitle: Text('${_fmtTime(s.createdAt)}  ·  ${_statusLabel(s.status)}'),
          onTap: () => _openDetail(s),
        );
      },
    );
  }

  String _statusLabel(LectureStatus s) {
    switch (s) {
      case LectureStatus.recorded:
        return '待转写';
      case LectureStatus.transcribing:
        return '转写中';
      case LectureStatus.transcribingModels:
        return '下载模型中';
      case LectureStatus.done:
        return '已完成';
      case LectureStatus.failed:
        return '失败';
    }
  }

  String _fmtTime(DateTime t) {
    return '${t.month}/${t.day} ${t.hour}:${t.minute.toString().padLeft(2, '0')}';
  }
}

/// 会话详情：转写 → 结果 → 笔记 → 导出。
class SessionDetailScreen extends StatefulWidget {
  const SessionDetailScreen({
    super.key,
    required this.session,
    required this.hotwords,
  });

  final LectureSession session;
  final String hotwords;

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  final LectureDb _db = LectureDb.instance;

  List<TranscriptSegment> _segments = [];
  LectureNote? _note;
  String _phase = '';
  double _fraction = 0;
  bool _busy = false;
  bool _noteBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final segs = await _db.segmentsFor(widget.session.id);
    final note = await _db.noteFor(widget.session.id);
    if (!mounted) return;
    setState(() {
      _segments = segs;
      _note = note;
    });
    if (widget.session.status == LectureStatus.recorded) {
      _transcribe();
    }
  }

  List<String> get _hotwordList => widget.hotwords
      .split(RegExp(r'[,，]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Future<void> _transcribe() async {
    setState(() {
      _busy = true;
      _phase = '检查模型';
    });
    await _db.updateSessionStatus(
        widget.session.id, LectureStatus.transcribing);

    try {
      // 首次运行先下载 sherpa-onnx 模型（约 1GB）。
      if (!await ModelManager.allReady()) {
        await _db.updateSessionStatus(
            widget.session.id, LectureStatus.transcribingModels);
        await ModelManager.ensureDownloaded(
          onProgress: (b, t, model, index, count) {
            if (mounted) {
              setState(() {
                _phase = '下载模型 $model（$index/$count）';
                _fraction = (b > 0 && t > 0) ? b / t : 0;
              });
            }
          },
        );
      }

      final models = EngineModels(
        asr: (await ModelManager.localPathFor('asr'))!,
        tokens: (await ModelManager.localPathFor('tokens'))!,
        vad: (await ModelManager.localPathFor('vad'))!,
        segmentation: (await ModelManager.localPathFor('segmentation'))!,
        embedding: (await ModelManager.localPathFor('embedding'))!,
      );

      final segs = await transcribeAudio(
        wavPath: widget.session.audioPath,
        models: models,
        hotwords: _hotwordList,
        onProgress: (phase, fraction) {
          if (mounted) {
            setState(() {
              _phase = phase;
              _fraction = fraction;
            });
          }
        },
      );

      await _db.saveSession(
        session: widget.session.copyWith(status: LectureStatus.done),
        segments: segs,
      );
      if (!mounted) return;
      setState(() {
        _segments = segs;
        _busy = false;
        _fraction = 1;
        _phase = '完成';
      });
    } catch (e) {
      await _db.updateSessionStatus(widget.session.id, LectureStatus.failed);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _phase = '失败';
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('转写失败：$e')));
    }
  }

  Future<void> _generateNote() async {
    if (_segments.isEmpty) return;
    setState(() => _noteBusy = true);
    try {
      final fullText = _segments
          .map((s) =>
              (s.speaker >= 0 ? '[说话人${s.speaker + 1}] ' : '') + s.text)
          .join('\n');
      final note = await generateNotes(
        transcriptText: fullText,
        hotwords: _hotwordList,
        title: widget.session.title,
      );
      await _db.saveSession(
        session: widget.session,
        note: note,
      );
      if (!mounted) return;
      setState(() {
        _note = note;
        _noteBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _noteBusy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('笔记生成失败：$e')));
    }
  }

  Future<void> _exportMarkdown() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = p.join(docs.path, 'notes');
    await Directory(dir).create(recursive: true);
    final path = p.join(
        dir, '${widget.session.title.replaceAll(' ', '_')}.md');

    final sb = StringBuffer();
    sb.writeln('# ${widget.session.title}\n');
    for (final s in _segments) {
      final tag = s.speaker >= 0 ? '说话人${s.speaker + 1}' : '??';
      final start = _fmtMs(s.startMs);
      final end = _fmtMs(s.endMs);
      sb.writeln('**[$start - $end] $tag**  ');
      sb.writeln('${s.text}\n');
    }
    if (_note != null) {
      sb.writeln('---\n');
      sb.writeln(_note!.toMarkdown());
    }
    await File(path).writeAsString(sb.toString());
    if (!mounted) return;
    Clipboard.setData(ClipboardData(text: sb.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导出到 $path（内容已复制到剪贴板）')),
    );
  }

  String _fmtMs(double ms) {
    final total = ms ~/ 1000;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: '导出 Markdown',
            onPressed: _segments.isEmpty ? null : _exportMarkdown,
          ),
        ],
      ),
      body: _busy
          ? _buildProgress()
          : _segments.isEmpty
              ? const Center(child: Text('暂无转写结果'))
              : _buildResult(),
    );
  }

  Widget _buildProgress() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_fraction < 0.05)
            const CircularProgressIndicator()
          else
            LinearProgressIndicator(value: _fraction),
          const SizedBox(height: 16),
          Text(_phase, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('${(_fraction * 100).toStringAsFixed(0)}%'),
        ],
      ),
    );
  }

  Widget _buildResult() {
    final speakers = _segments
        .where((s) => s.speaker >= 0)
        .map((s) => s.speaker)
        .toSet()
        .toList()
      ..sort();
    final colors = [
      Colors.blue,
      Colors.deepOrange,
      Colors.teal,
      Colors.purple,
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_segments.any((s) => s.speaker >= 0))
          Wrap(
            spacing: 8,
            children: [
              for (final spk in speakers)
                Chip(
                  avatar: CircleAvatar(
                    backgroundColor: colors[spk % colors.length],
                    child: Text('${spk + 1}'),
                  ),
                  label: Text('说话人${spk + 1}'),
                ),
            ],
          ),
        const SizedBox(height: 8),
        for (final s in _segments)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (s.speaker >= 0)
                  Container(
                    margin: const EdgeInsets.only(right: 8, top: 4),
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: colors[s.speaker % colors.length],
                      shape: BoxShape.circle,
                    ),
                  ),
                Expanded(
                  child: Text(
                    s.text,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              ],
            ),
          ),
        const Divider(height: 32),
        _buildNoteSection(),
      ],
    );
  }

  Widget _buildNoteSection() {
    if (_noteBusy) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_note != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('课堂笔记', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          if (_note!.summary.isNotEmpty)
            Text(_note!.summary,
                style: Theme.of(context).textTheme.bodyLarge),
          _noteList('要点', _note!.keyPoints),
          _noteList('术语', _note!.terms),
          _noteList('考点', _note!.examHints),
          _noteList('疑问', _note!.questions),
        ],
      );
    }
    return FilledButton.icon(
      onPressed: _generateNote,
      icon: const Icon(Icons.auto_awesome),
      label: const Text('用 DeepSeek 生成课堂笔记'),
    );
  }

  Widget _noteList(String title, List<String> items) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 4),
              child: Text('• $item'),
            ),
        ],
      ),
    );
  }
}
