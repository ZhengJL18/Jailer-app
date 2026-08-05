/// 课堂笔记主屏（以笔记为中心）。
///
/// 三栏布局：
/// - 左栏：科目 → 笔记树 + 全文搜索
/// - 主区：Markdown 笔记编辑器（源码 / 预览切换），自动保存
/// - 右栏：当前笔记的音频面板 —— 导入音频 / 录音 → 转写（说话人分离）→
///   一键生成笔记（DeepSeek），生成结果插入正文并回填科目热词
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
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
import 'note_editor.dart';

class LectureScreen extends StatefulWidget {
  const LectureScreen({super.key});

  @override
  State<LectureScreen> createState() => _LectureScreenState();
}

class _LectureScreenState extends State<LectureScreen> {
  final LectureDb _db = LectureDb.instance;
  final RecordingService _recorder = RecordingService();

  // 导航。
  List<LectureSubject> _subjects = [];
  final Map<String, List<Note>> _notesCache = {};
  String? _expandedSubjectId;
  Note? _currentNote;

  // 编辑器 + 自动保存。
  final TextEditingController _editorController = TextEditingController();
  Timer? _saveTimer;
  String _saveState = '';
  bool _loadingNote = false;

  // 音频面板。
  List<NoteAudio> _audio = [];
  String? _transcribingAudioId;
  String _transcribePhase = '';
  double _transcribeFraction = 0;
  bool _generating = false;
  bool _recording = false;

  // 搜索。
  String _searchQuery = '';
  List<Note> _searchResults = [];

  String? get _currentNoteId => _currentNote?.id;

  @override
  void initState() {
    super.initState();
    _refreshSubjects();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _editorController.dispose();
    _recorder.cancel();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── 数据加载 ──────────────────────────────────────────

  Future<void> _refreshSubjects() async {
    final subjects = await _db.listSubjects();
    if (!mounted) return;
    setState(() => _subjects = subjects);
    if (_expandedSubjectId == null && subjects.isNotEmpty) {
      _expandedSubjectId = subjects.first.id;
      await _loadNotesForExpanded();
    }
    if (_currentNote == null && _expandedSubjectId != null) {
      final notes = _notesCache[_expandedSubjectId] ?? const [];
      if (notes.isNotEmpty) await _selectNote(notes.first.id);
    }
  }

  Future<void> _loadNotesForExpanded() async {
    final sid = _expandedSubjectId;
    if (sid == null) return;
    final notes = await _db.listNotes(sid);
    if (!mounted) return;
    setState(() => _notesCache[sid] = notes);
  }

  Future<void> _selectNote(String noteId) async {
    final note = await _db.getNote(noteId);
    if (note == null) return;
    setState(() {
      _loadingNote = true;
      _currentNote = note;
      _searchQuery = '';
      _searchResults = [];
    });
    _editorController.text = note.content;
    final audio = await _db.listAudio(noteId);
    if (!mounted) return;
    setState(() {
      _audio = audio;
      _loadingNote = false;
      _saveState = '已保存';
      _transcribingAudioId = null;
      _transcribePhase = '';
      _transcribeFraction = 0;
    });
  }

  // ── 自动保存 ──────────────────────────────────────────

  void _onEditorChanged() {
    if (_loadingNote || _currentNoteId == null) return;
    if (mounted) setState(() => _saveState = '保存中…');
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), () async {
      await _db.updateNoteContent(_currentNoteId!, _editorController.text);
      if (!mounted) return;
      setState(() => _saveState = '已保存');
    });
  }

  // ── 科目 / 笔记操作 ───────────────────────────────────

  Future<void> _addSubject() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建科目'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '科目名（如：方剂学）'),
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
    if (name == null || name.trim().isEmpty) return;
    final subject = await _db.createSubject(name);
    await _refreshSubjects();
    if (mounted) {
      setState(() {
        _expandedSubjectId = subject.id;
        _notesCache[subject.id] = [];
      });
    }
  }

  Future<void> _addNote(String subjectId) async {
    final note = await _db.createNote(subjectId: subjectId);
    if (!mounted) return;
    setState(() {
      _expandedSubjectId = subjectId;
      _notesCache[subjectId] = [
        note,
        ...?_notesCache[subjectId],
      ];
    });
    await _selectNote(note.id);
    _snack('已新建笔记');
  }

  Future<void> _renameNote(Note note) async {
    final ctrl = TextEditingController(text: note.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名笔记'),
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
    if (newTitle == null || newTitle.trim().isEmpty) return;
    await _db.updateNoteMeta(note.id, title: newTitle);
    await _loadNotesForExpanded();
    if (_currentNoteId == note.id) {
      setState(() =>
          _currentNote = _currentNote!.copyWith(title: newTitle.trim()));
    }
  }

  Future<void> _togglePin(Note note) async {
    await _db.updateNoteMeta(note.id, pinned: !note.pinned);
    await _loadNotesForExpanded();
    if (_currentNoteId == note.id) {
      setState(() =>
          _currentNote = _currentNote!.copyWith(pinned: !note.pinned));
    }
  }

  Future<void> _deleteNote(Note note) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除笔记「${note.title}」？'),
        content: const Text('该笔记及其音频转写记录将被删除，不可恢复。'),
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
    if (confirm != true) return;
    await _db.deleteNote(note.id);
    if (_currentNoteId == note.id) {
      _currentNote = null;
      _editorController.clear();
      _audio = [];
    }
    await _loadNotesForExpanded();
    if (mounted) setState(() {});
  }

  Future<void> _deleteSubject(LectureSubject subject) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除科目「${subject.name}」？'),
        content: const Text('该科目下的笔记与热词将一并删除，不可恢复。'),
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
    if (confirm != true) return;
    final notes = await _db.listNotes(subject.id);
    for (final n in notes) {
      await _db.deleteNote(n.id);
    }
    await _db.deleteSubject(subject.id);
    if (_currentNoteId != null &&
        _currentNote!.subjectId == subject.id) {
      _currentNote = null;
      _editorController.clear();
      _audio = [];
    }
    if (mounted) {
      setState(() {
        _expandedSubjectId = null;
        _notesCache.remove(subject.id);
      });
    }
    await _refreshSubjects();
  }

  // ── 搜索 ──────────────────────────────────────────────

  Future<void> _runSearch(String q) async {
    if (q.trim().isEmpty) {
      setState(() {
        _searchQuery = '';
        _searchResults = [];
      });
      return;
    }
    final results = await _db.searchNotes(q);
    if (!mounted) return;
    setState(() {
      _searchQuery = q;
      _searchResults = results;
    });
  }

  // ── 音频面板 ──────────────────────────────────────────

  Future<void> _importAudio() async {
    if (_currentNoteId == null) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['m4a', 'mp3', 'wav', 'flac', 'aac', 'ogg', 'amr'],
      dialogTitle: '选择课堂录音',
    );
    if (result == null || result.files.isEmpty) return;
    final srcPath = result.files.single.path;
    if (srcPath == null) return;

    final docs = await getApplicationDocumentsDirectory();
    final dir = p.join(docs.path, 'audio');
    await Directory(dir).create(recursive: true);
    final dst = p.join(
      dir,
      '${DateTime.now().millisecondsSinceEpoch}${p.extension(srcPath)}',
    );
    await File(srcPath).copy(dst);

    final audio = await _db.addAudio(noteId: _currentNoteId!, path: dst);
    if (!mounted) return;
    setState(() => _audio = [audio, ..._audio]);
    _snack('已导入音频，点「转写」开始识别');
  }

  Future<void> _transcribeAudio(NoteAudio audio) async {
    setState(() {
      _transcribingAudioId = audio.id;
      _transcribePhase = '检查模型';
      _transcribeFraction = 0;
    });
    await _db.updateAudio(audio.id, status: AudioStatus.transcribing);

    try {
      if (!await ModelManager.allReady()) {
        await ModelManager.ensureDownloaded(
          onProgress: (b, t, model, index, count) {
            if (mounted) {
              setState(() {
                _transcribePhase = '下载模型 $model（$index/$count）';
                _transcribeFraction = (b > 0 && t > 0) ? b / t : 0;
              });
            }
          },
        );
      }

      final note = await _db.getNote(_currentNoteId!);
      if (note == null) throw StateError('笔记不存在');
      final hotwords = _hotwordsFor(note.subjectId);

      final models = EngineModels(
        asr: (await ModelManager.localPathFor('asr'))!,
        tokens: (await ModelManager.localPathFor('tokens'))!,
        vad: (await ModelManager.localPathFor('vad'))!,
        segmentation: (await ModelManager.localPathFor('segmentation'))!,
        embedding: (await ModelManager.localPathFor('embedding'))!,
      );

      final segs = await transcribeAudio(
        wavPath: audio.path,
        models: models,
        hotwords: hotwords,
        onProgress: (phase, fraction) {
          if (mounted) {
            setState(() {
              _transcribePhase = phase;
              _transcribeFraction = fraction;
            });
          }
        },
      );

      final transcript = segs
          .map((s) =>
              (s.speaker >= 0 ? '[说话人${s.speaker + 1}] ' : '') + s.text)
          .join('\n');

      await _db.updateAudio(
        audio.id,
        transcript: transcript,
        status: AudioStatus.done,
      );
      if (!mounted) return;
      setState(() {
        _audio = [
          for (final a in _audio)
            if (a.id == audio.id)
              a.copyWith(transcript: transcript, status: AudioStatus.done)
            else
              a
        ];
        _transcribingAudioId = null;
        _transcribeFraction = 1;
      });
    } catch (e) {
      await _db.updateAudio(audio.id, status: AudioStatus.failed);
      if (!mounted) return;
      setState(() {
        _transcribingAudioId = null;
        _transcribePhase = '';
      });
      _snack('转写失败：$e');
    }
  }

  /// 一键生成：DeepSeek 把转写整理成 Markdown，插入笔记正文，术语回填热词。
  Future<void> _generateNoteFromAudio(NoteAudio audio) async {
    if (audio.transcript.trim().isEmpty) {
      _snack('请先转写这段音频');
      return;
    }
    setState(() => _generating = true);
    try {
      final note = await _db.getNote(_currentNoteId!);
      if (note == null) throw StateError('笔记不存在');
      final hotwords = _hotwordsFor(note.subjectId);
      final subject = _subjectOf(note.subjectId);

      final gen = await generateNoteMarkdown(
        transcriptText: audio.transcript,
        hotwords: hotwords,
        title: note.title,
      );

      await _db.appendToNote(note.id, gen.markdown);
      var added = 0;
      if (subject != null) {
        added = await harvestTermsFromNote(
            subjectId: subject.id, note: _noteFromGen(gen));
      }
      if (!mounted) return;
      setState(() {
        if (gen.markdown.trim().isNotEmpty) {
          final base = _editorController.text;
          _editorController.text =
              base.trim().isEmpty ? gen.markdown : '$base\n\n${gen.markdown}';
        }
        _generating = false;
        _saveState = '已保存';
      });
      _snack(added > 0
          ? '笔记已生成，并回填 $added 个热词到「${subject?.name ?? ''}」'
          : '笔记已生成');
    } catch (e) {
      if (!mounted) return;
      setState(() => _generating = false);
      _snack('生成失败：$e');
    }
  }

  LectureNote _noteFromGen(NoteGeneration gen) {
    return LectureNote(
      summary: '',
      keyPoints: [],
      terms: gen.terms,
      examHints: [],
      questions: [],
    );
  }

  List<String> _hotwordsFor(String subjectId) {
    final s = _subjectOf(subjectId);
    return s == null ? const [] : s.hotwords;
  }

  LectureSubject? _subjectOf(String? subjectId) {
    if (subjectId == null) return null;
    for (final s in _subjects) {
      if (s.id == subjectId) return s;
    }
    return null;
  }

  Future<void> _deleteAudio(NoteAudio audio) async {
    await _db.deleteAudio(audio.id);
    if (mounted) {
      setState(() => _audio = _audio.where((a) => a.id != audio.id).toList());
    }
  }

  // 录音：start/stop 切换，停止后导入当前笔记。
  Future<void> _toggleRecord() async {
    if (_recording) {
      final path = await _recorder.stop();
      setState(() => _recording = false);
      if (path == null || path.isEmpty || !await File(path).exists()) {
        _snack('未获得录音文件');
        return;
      }
      final audio = await _db.addAudio(noteId: _currentNoteId!, path: path);
      if (!mounted) return;
      setState(() => _audio = [audio, ..._audio]);
      _snack('录音已保存，点「转写」开始识别');
    } else {
      if (_currentNoteId == null) return;
      try {
        final path = await _recorder.start();
        if (path.isEmpty) return;
        setState(() => _recording = true);
        _snack('录音中…');
      } catch (e) {
        _snack('录音失败：$e');
      }
    }
  }

  // ── 导出 ──────────────────────────────────────────────

  Future<void> _exportNote(Note note) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = p.join(docs.path, 'notes');
    await Directory(dir).create(recursive: true);
    final path = p.join(dir, '${note.title.replaceAll(' ', '_')}.md');
    final content = '# ${note.title}\n\n${_editorController.text}';
    await File(path).writeAsString(content);
    Clipboard.setData(ClipboardData(text: content));
    _snack('已导出到 $path');
  }

  // ── 构建 ──────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('课堂笔记')),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 260, child: _buildNavPane(context)),
          const VerticalDivider(width: 1),
          Expanded(child: _buildEditorPane(context)),
          const VerticalDivider(width: 1),
          SizedBox(width: 320, child: _buildAudioPane(context)),
        ],
      ),
    );
  }

  // 左栏：科目 → 笔记树 + 搜索。
  Widget _buildNavPane(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            onChanged: _runSearch,
            decoration: InputDecoration(
              hintText: '搜索笔记…',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child:
              _searchQuery.isNotEmpty ? _buildSearchList() : _buildSubjectTree(),
        ),
      ],
    );
  }

  Widget _buildSearchList() {
    if (_searchResults.isEmpty) {
      return const Center(child: Text('无匹配结果'));
    }
    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (context, i) {
        final n = _searchResults[i];
        final subj = _subjectOf(n.subjectId);
        return ListTile(
          dense: true,
          title: Text(n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            subj?.name ?? '',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          selected: n.id == _currentNoteId,
          onTap: () => _selectNote(n.id),
        );
      },
    );
  }

  Widget _buildSubjectTree() {
    if (_subjects.isEmpty) {
      return Center(
        child: FilledButton.icon(
          onPressed: _addSubject,
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('新建科目'),
        ),
      );
    }
    return ListView(
      children: [
        for (final subject in _subjects) _buildSubjectTile(subject),
        Padding(
          padding: const EdgeInsets.all(8),
          child: OutlinedButton.icon(
            onPressed: _addSubject,
            icon: const Icon(Icons.add),
            label: const Text('科目'),
          ),
        ),
      ],
    );
  }

  Widget _buildSubjectTile(LectureSubject subject) {
    final expanded = _expandedSubjectId == subject.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          dense: true,
          leading: const Icon(Icons.folder, size: 20),
          title: Text(
            subject.name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          trailing: Text(
            '${subject.hotwords.length}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          onTap: () async {
            setState(() {
              _expandedSubjectId = expanded ? null : subject.id;
            });
            if (!expanded) await _loadNotesForExpanded();
          },
          onLongPress: () => _deleteSubject(subject),
        ),
        if (expanded) ...[
          for (final note in (_notesCache[subject.id] ?? const []))
            _buildNoteTile(note),
          Padding(
            padding: const EdgeInsets.only(left: 24, bottom: 4),
            child: TextButton.icon(
              onPressed: () => _addNote(subject.id),
              icon: const Icon(Icons.note_add_outlined, size: 18),
              label: const Text('新建笔记'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildNoteTile(Note note) {
    return ListTile(
      dense: true,
      leading: Icon(
        note.pinned ? Icons.push_pin : Icons.description_outlined,
        size: 18,
      ),
      title: Text(
        note.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: note.id == _currentNoteId
              ? Theme.of(context).colorScheme.primary
              : null,
        ),
      ),
      selected: note.id == _currentNoteId,
      onTap: () => _selectNote(note.id),
      onLongPress: () => _showNoteMenu(note),
    );
  }

  void _showNoteMenu(Note note) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(ctx);
                _renameNote(note);
              },
            ),
            ListTile(
              leading: Icon(
                  note.pinned ? Icons.push_pin_outlined : Icons.push_pin),
              title: Text(note.pinned ? '取消置顶' : '置顶'),
              onTap: () {
                Navigator.pop(ctx);
                _togglePin(note);
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('导出 Markdown'),
              onTap: () {
                Navigator.pop(ctx);
                _exportNote(note);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteNote(note);
              },
            ),
          ],
        ),
      ),
    );
  }

  // 主区：编辑器。
  Widget _buildEditorPane(BuildContext context) {
    final note = _currentNote;
    return Column(
      children: [
        if (note != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    note.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(_saveState,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.ios_share, size: 20),
                  tooltip: '导出 Markdown',
                  onPressed: () => _exportNote(note),
                ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: note == null
              ? const Center(child: Text('选择或新建一篇笔记开始'))
              : NoteEditor(
                  controller: _editorController,
                  onChanged: (_) => _onEditorChanged(),
                ),
        ),
      ],
    );
  }

  // 右栏：音频面板。
  Widget _buildAudioPane(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Text('音频', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.library_music_outlined),
                tooltip: '导入音频',
                onPressed: _currentNoteId == null ? null : _importAudio,
              ),
              IconButton(
                icon: _recording
                    ? const Icon(Icons.stop, color: Colors.red)
                    : const Icon(Icons.fiber_manual_record,
                        color: Colors.red),
                tooltip: _recording ? '停止录音' : '录音',
                onPressed: _currentNoteId == null ? null : _toggleRecord,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _currentNoteId == null
              ? const Center(child: Text('选中一篇笔记后导入音频'))
              : _audio.isEmpty
                  ? const Center(
                      child: Text('还没有音频\n点右上角导入录音文件或直接录音'),
                    )
                  : ListView.builder(
                      itemCount: _audio.length,
                      itemBuilder: (context, i) => _buildAudioTile(_audio[i]),
                    ),
        ),
      ],
    );
  }

  Widget _buildAudioTile(NoteAudio audio) {
    final isTranscribing = _transcribingAudioId == audio.id;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(_audioIcon(audio.status), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    p.basename(audio.path),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'delete') _deleteAudio(audio);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ],
            ),
            if (audio.durationSec > 0)
              Text(
                '时长 ${audio.durationSec ~/ 60}分${audio.durationSec % 60}秒',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
            if (isTranscribing) ...[
              LinearProgressIndicator(value: _transcribeFraction),
              const SizedBox(height: 4),
              Text(_transcribePhase,
                  style: Theme.of(context).textTheme.bodySmall),
            ] else if (audio.status == AudioStatus.done &&
                audio.transcript.isNotEmpty)
              Text(
                '已转写 ${audio.transcript.length} 字',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              Text(_audioStatusLabel(audio.status),
                  style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed:
                      isTranscribing ? null : () => _transcribeAudio(audio),
                  icon: const Icon(Icons.transcribe, size: 18),
                  label: const Text('转写'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed:
                      isTranscribing || _generating
                          ? null
                          : () => _generateNoteFromAudio(audio),
                  icon: _generating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('一键生成笔记'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _audioIcon(AudioStatus s) {
    switch (s) {
      case AudioStatus.ready:
        return Icons.radio_button_checked;
      case AudioStatus.transcribing:
        return Icons.autorenew;
      case AudioStatus.done:
        return Icons.check_circle;
      case AudioStatus.failed:
        return Icons.error_outline;
    }
  }

  String _audioStatusLabel(AudioStatus s) {
    switch (s) {
      case AudioStatus.ready:
        return '待转写';
      case AudioStatus.transcribing:
        return '转写中…';
      case AudioStatus.done:
        return '已转写';
      case AudioStatus.failed:
        return '转写失败';
    }
  }
}
