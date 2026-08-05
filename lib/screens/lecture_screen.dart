/// 课堂笔记主屏。
///
/// 录音 → 转写（带说话人分离）→ DeepSeek 总结 → 本地笔记 + Markdown 导出。
/// 提供四个 Tab：录音转写 / 笔记库 / 录音库 / 科目热词。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../lecture/deepseek_notes.dart';
import '../lecture/hotword_learner.dart';
import '../lecture/lecture_db.dart';
import '../lecture/model_manager.dart';
import '../lecture/models.dart';
import '../lecture/recording_service.dart';
import '../lecture/transcription_engine.dart';

class LectureScreen extends StatefulWidget {
  const LectureScreen({super.key});

  @override
  State<LectureScreen> createState() => _LectureScreenState();
}

class _LectureScreenState extends State<LectureScreen> {
  final RecordingService _recorder = RecordingService();
  final LectureDb _db = LectureDb.instance;

  int _tab = 0;
  bool _isRecording = false;
  Timer? _recordTimer;
  int _recordSeconds = 0;

  List<LectureSession> _sessions = [];
  List<LectureSubject> _subjects = [];
  String? _selectedSubjectId;
  String _extraHotwords = '';

  @override
  void initState() {
    super.initState();
    _refreshAll();
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    final sessions = await _db.listSessions();
    final subjects = await _db.listSubjects();
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _subjects = subjects;
      if (_selectedSubjectId == null && subjects.isNotEmpty) {
        _selectedSubjectId = subjects.first.id;
      }
    });
  }

  // ── 录音 ──────────────────────────────────────────────

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
      title: _sessionTitle(),
      audioPath: path,
      createdAt: DateTime.now(),
      status: LectureStatus.recorded,
      subjectId: _selectedSubjectId,
      durationSec: _recordSeconds,
    );
    await _db.saveSession(session: session);
    _refreshAll();
    _openDetail(session);
  }

  String _sessionTitle() {
    final date = DateTime.now();
    return '录音 ${date.month}月${date.day}日 ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }

  void _openDetail(LectureSession session, {String? extraHotwords}) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => SessionDetailScreen(
              session: session,
              subjects: _subjects,
              extraHotwords: extraHotwords ?? _extraHotwords,
            ),
          ),
        )
        .then((_) => _refreshAll());
  }

  // ── 科目 / 热词 ───────────────────────────────────────

  Future<void> _addSubject() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建科目'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '科目名（如：方剂学）',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('创建')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      final subj = await _db.createSubject(name);
      await _refreshAll();
      setState(() => _selectedSubjectId = subj.id);
    }
  }

  Future<void> _manageHotwords(LectureSubject subject) async {
    final ctrl = TextEditingController();
    final add = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${subject.name} · 热词'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('已有 ${subject.hotwords.length} 个热词',
                  style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '添加热词（逗号分隔多个）',
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('关闭')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('添加')),
        ],
      ),
    );
    if (add == true && ctrl.text.trim().isNotEmpty) {
      final words = ctrl.text
          .split(RegExp(r'[,，]'))
          .map((w) => w.trim())
          .where((w) => w.isNotEmpty)
          .toList();
      await _db.addHotwords(subject.id, words);
      _refreshAll();
    }
  }

  // ── 设置 ──────────────────────────────────────────────

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

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── 构建 ──────────────────────────────────────────────

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
        bottom: TabBar(
          onTap: (i) => setState(() => _tab = i),
          tabs: const [
            Tab(text: '录音转写'),
            Tab(text: '笔记库'),
            Tab(text: '录音库'),
            Tab(text: '科目热词'),
          ],
        ),
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          _buildRecordTab(context),
          _buildNotesTab(context),
          _buildRecordingsTab(context),
          _buildSubjectsTab(context),
        ],
      ),
    );
  }

  // ── Tab 0：录音转写 ───────────────────────────────────

  Widget _buildRecordTab(BuildContext context) {
    final mm = (_recordSeconds ~/ 60).toString().padLeft(2, '0');
    final ss = (_recordSeconds % 60).toString().padLeft(2, '0');
    final currentSubject = _subjects
        .where((s) => s.id == _selectedSubjectId)
        .toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _isRecording ? '正在录音  $mm:$ss' : '开始一节新课堂',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton.filled(
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
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_subjects.isEmpty)
          FilledButton.tonalIcon(
            onPressed: _addSubject,
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('先建一个科目（如：方剂学）'),
          )
        else
          DropdownButtonFormField<String>(
            initialValue: _selectedSubjectId,
            decoration: const InputDecoration(
              labelText: '科目（自动带上该科目的热词）',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final s in _subjects)
                DropdownMenuItem(
                  value: s.id,
                  child: Text('${s.name}（${s.hotwords.length} 热词）'),
                ),
            ],
            onChanged: (v) => setState(() => _selectedSubjectId = v),
          ),
        if (currentSubject.isNotEmpty &&
            currentSubject.first.hotwords.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final w in currentSubject.first.hotwords.take(12))
                Chip(label: Text(w), visualDensity: VisualDensity.compact),
              if (currentSubject.first.hotwords.length > 12)
                Chip(
                  label: Text('+${currentSubject.first.hotwords.length - 12}'),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        TextField(
          decoration: const InputDecoration(
            labelText: '本次额外热词（逗号分隔，临时补充）',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => _extraHotwords = v,
        ),
        const SizedBox(height: 8),
        Text(
          '提示：录音后自动转写 + 说话人分离，再用 DeepSeek 生成笔记；'
          '笔记中的术语会回填到科目热词库，越用越准。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  // ── Tab 1：笔记库 ─────────────────────────────────────

  Widget _buildNotesTab(BuildContext context) {
    final withNotes =
        _sessions.where((s) => s.status == LectureStatus.done).toList();
    if (withNotes.isEmpty) {
      return const Center(child: Text('还没有生成过笔记'));
    }
    return ListView.builder(
      itemCount: withNotes.length,
      itemBuilder: (context, i) {
        final s = withNotes[i];
        return ListTile(
          leading: const Icon(Icons.article_outlined),
          title: Text(s.title),
          subtitle: Text('${_fmtTime(s.createdAt)}  ·  ${_subjectName(s.subjectId)}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openDetail(s),
        );
      },
    );
  }

  // ── Tab 2：录音库 ─────────────────────────────────────

  Widget _buildRecordingsTab(BuildContext context) {
    if (_sessions.isEmpty) {
      return const Center(child: Text('还没有录音'));
    }
    return ListView.builder(
      itemCount: _sessions.length,
      itemBuilder: (context, i) {
        final s = _sessions[i];
        final dur = s.durationSec > 0
            ? '  ·  ${_fmtDuration(s.durationSec)}'
            : '';
        return ListTile(
          leading: Icon(
            s.status == LectureStatus.done
                ? Icons.check_circle
                : s.status == LectureStatus.transcribing
                    ? Icons.autorenew
                    : Icons.radio_button_checked,
          ),
          title: Text(s.title),
          subtitle:
              Text('${_fmtTime(s.createdAt)}${dur}  ·  ${_statusLabel(s.status)}'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PopupMenuButton<String>(
                tooltip: '管理',
                onSelected: (v) => _handleRecordingAction(s, v),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      value: 'rename', child: Text('重命名')),
                  PopupMenuItem(
                      value: 'subject', child: Text('更换科目')),
                  PopupMenuItem(
                      value: 'delete', child: Text('删除录音')),
                ],
              ),
            ],
          ),
          onTap: () => _openDetail(s),
        );
      },
    );
  }

  Future<void> _handleRecordingAction(
      LectureSession session, String action) async {
    switch (action) {
      case 'rename':
        final ctrl = TextEditingController(text: session.title);
        final newTitle = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('重命名'),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: '标题'),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, ctrl.text),
                  child: const Text('保存')),
            ],
          ),
        );
        if (newTitle != null && newTitle.trim().isNotEmpty) {
          await _db.renameSession(session.id, newTitle);
          _refreshAll();
        }
      case 'subject':
        final newSubject = await _showSubjectPicker(session.subjectId);
        if (newSubject != null) {
          await _db.setSessionSubject(session.id, newSubject);
          _refreshAll();
        }
      case 'delete':
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除录音？'),
            content: const Text('删除后转写与笔记一并清除，不可恢复。'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消')),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (confirm == true) {
          await _db.deleteSession(session.id);
          try {
            final f = File(session.audioPath);
            if (await f.exists()) await f.delete();
          } catch (_) {}
          _refreshAll();
        }
    }
  }

  Future<String?> _showSubjectPicker(String? current) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择科目'),
        children: [
          if (_subjects.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('还没有科目，请先到「科目热词」页创建'),
            )
          else ...[
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('不分类'),
            ),
            for (final s in _subjects)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, s.id),
                child: Text(s.name),
              ),
          ],
        ],
      ),
    );
    return picked;
  }

  // ── Tab 3：科目热词 ───────────────────────────────────

  Widget _buildSubjectsTab(BuildContext context) {
    if (_subjects.isEmpty) {
      return Center(
        child: FilledButton.icon(
          onPressed: _addSubject,
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('新建科目'),
        ),
      );
    }
    return ListView.builder(
      itemCount: _subjects.length,
      itemBuilder: (context, i) {
        final s = _subjects[i];
        return ExpansionTile(
          leading: const Icon(Icons.school),
          title: Text(s.name),
          subtitle: Text('${s.hotwords.length} 个热词'),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final w in s.hotwords)
                    InputChip(
                      label: Text(w),
                      onDeleted: () async {
                        await _db.removeHotword(s.id, w);
                        _refreshAll();
                      },
                    ),
                  if (s.hotwords.isEmpty)
                    Text('暂无热词 — 转写并生成笔记后会自动积累',
                        style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => _manageHotwords(s),
                    icon: const Icon(Icons.add),
                    label: const Text('添加热词'),
                  ),
                  TextButton.icon(
                    onPressed: () => _renameSubject(s),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('重命名'),
                  ),
                  TextButton.icon(
                    onPressed: () => _deleteSubject(s),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('删除'),
                  ),
                ],
              ),
            ),
            const Divider(),
          ],
        );
      },
    );
  }

  Future<void> _renameSubject(LectureSubject subject) async {
    final ctrl = TextEditingController(text: subject.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名科目'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (newName != null && newName.trim().isNotEmpty) {
      await _db.renameSubject(subject.id, newName);
      _refreshAll();
    }
  }

  Future<void> _deleteSubject(LectureSubject subject) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除科目「${subject.name}」？'),
        content: const Text('该科目的热词库将被清除，已有录音/笔记保留但不再分类。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _db.deleteSubject(subject.id);
      _refreshAll();
    }
  }

  // ── 工具 ──────────────────────────────────────────────

  String _subjectName(String? id) {
    if (id == null) return '未分类';
    final found = _subjects.where((s) => s.id == id).toList();
    return found.isEmpty ? '未分类' : found.first.name;
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

  String _fmtDuration(int sec) {
    final m = sec ~/ 60;
    final s = sec % 60;
    return '${m}m${s.toString().padLeft(2, '0')}s';
  }
}

/// 会话详情：转写 → 结果 → 笔记 → 导出。
class SessionDetailScreen extends StatefulWidget {
  const SessionDetailScreen({
    super.key,
    required this.session,
    required this.subjects,
    this.extraHotwords = '',
  });

  final LectureSession session;
  final List<LectureSubject> subjects;

  /// 录音时用户输入的本次额外热词。
  final String extraHotwords;

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

  /// 转写热词：科目热词库 + 会话额外热词合并。
  List<String> get _mergedHotwords {
    final subject = widget.subjects
        .where((s) => s.id == widget.session.subjectId)
        .toList();
    final base = subject.isEmpty ? <String>[] : subject.first.hotwords;
    final extra = widget.extraHotwords
        .split(RegExp(r'[,，]'))
        .map((w) => w.trim())
        .where((w) => w.isNotEmpty)
        .toList();
    final seen = <String>{...base, ...extra};
    return seen.toList();
  }

  Future<void> _transcribe() async {
    setState(() {
      _busy = true;
      _phase = '检查模型';
    });
    await _db.updateSessionStatus(
        widget.session.id, LectureStatus.transcribing);

    try {
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
        hotwords: _mergedHotwords,
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
        hotwords: _mergedHotwords,
        title: widget.session.title,
      );
      await _db.saveSession(
        session: widget.session,
        note: note,
      );

      // 热词自进化：笔记术语回填科目热词库。
      final subjectId = widget.session.subjectId;
      if (subjectId != null) {
        final added =
            await harvestTermsFromNote(subjectId: subjectId, note: note);
        if (added > 0) {
          _snack('已自动补充 $added 个热词到该科目');
        }
      }

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
    final path =
        p.join(dir, '${widget.session.title.replaceAll(' ', '_')}.md');

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

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.title),
        actions: [
          if (_note != null)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '编辑笔记',
              onPressed: _editNote,
            ),
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

  Future<void> _editNote() async {
    final note = _note;
    if (note == null) return;
    final result = await Navigator.of(context).push<LectureNote>(
      MaterialPageRoute(
        builder: (_) => NoteEditorScreen(note: note),
      ),
    );
    if (result != null) {
      await _db.updateNote(widget.session.id, result);
      setState(() => _note = result);
      _snack('笔记已保存');
    }
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
            Text(_note!.summary, style: Theme.of(context).textTheme.bodyLarge),
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

/// 笔记编辑器：可改摘要/要点/术语/考点/疑问，保存返回 LectureNote。
class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({super.key, required this.note});

  final LectureNote note;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late TextEditingController _summary;
  late TextEditingController _keyPoints;
  late TextEditingController _terms;
  late TextEditingController _examHints;
  late TextEditingController _questions;

  @override
  void initState() {
    super.initState();
    _summary = TextEditingController(text: widget.note.summary);
    _keyPoints = TextEditingController(text: widget.note.keyPoints.join('\n'));
    _terms = TextEditingController(text: widget.note.terms.join('\n'));
    _examHints = TextEditingController(text: widget.note.examHints.join('\n'));
    _questions =
        TextEditingController(text: widget.note.questions.join('\n'));
  }

  @override
  void dispose() {
    _summary.dispose();
    _keyPoints.dispose();
    _terms.dispose();
    _examHints.dispose();
    _questions.dispose();
    super.dispose();
  }

  List<String> _lines(String s) =>
      s.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  void _save() {
    Navigator.of(context).pop(
      LectureNote(
        summary: _summary.text.trim(),
        keyPoints: _lines(_keyPoints.text),
        terms: _lines(_terms.text),
        examHints: _lines(_examHints.text),
        questions: _lines(_questions.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑笔记'),
        actions: [
          FilledButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _summary,
            decoration: const InputDecoration(
              labelText: '概述',
              border: OutlineInputBorder(),
            ),
            maxLines: 3,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _keyPoints,
            decoration: const InputDecoration(
              labelText: '要点（每行一个）',
              border: OutlineInputBorder(),
            ),
            maxLines: 6,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _terms,
            decoration: const InputDecoration(
              labelText: '术语（每行一个）',
              border: OutlineInputBorder(),
            ),
            maxLines: 5,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _examHints,
            decoration: const InputDecoration(
              labelText: '考点（每行一个）',
              border: OutlineInputBorder(),
            ),
            maxLines: 5,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _questions,
            decoration: const InputDecoration(
              labelText: '疑问（每行一个）',
              border: OutlineInputBorder(),
            ),
            maxLines: 4,
          ),
        ],
      ),
    );
  }
}
