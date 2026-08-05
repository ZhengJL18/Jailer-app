/// sherpa-onnx 离线转写引擎。
///
/// 流程：读 WAV → VAD 切段 → Paraformer 逐段转写 → Pyannote+NeMo 说话人
/// 分离 → 按时间对齐合并成「说话人 + 时间戳 + 文本」段列表。
/// 全部推理在后台 isolate 执行，不阻塞 UI。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import 'models.dart';

/// 转写进度回调：[phase] 阶段名，[fraction] 0~1。
typedef TranscribeProgress = void Function(String phase, double fraction);

/// 需要加载的模型路径集合。
class EngineModels {
  const EngineModels({
    required this.asr,
    required this.tokens,
    required this.vad,
    required this.segmentation,
    required this.embedding,
  });

  final String asr;
  final String tokens;
  final String vad;
  final String segmentation;
  final String embedding;
}

/// 一次转写调用的完整参数（sendable，供后台 isolate 使用）。
class TranscribeRequest {
  TranscribeRequest({
    required this.wavPath,
    required this.models,
    required this.hotwords,
    required this.numThreads,
    required this.replyPort,
  });

  final String wavPath;
  final EngineModels models;
  final List<String> hotwords;
  final int numThreads;
  final SendPort replyPort;
}

/// 把音频转写为带说话人标签的段列表。
Future<List<TranscriptSegment>> transcribeAudio({
  required String wavPath,
  required EngineModels models,
  List<String> hotwords = const [],
  int numThreads = 4,
  TranscribeProgress? onProgress,
}) async {
  final replyPort = ReceivePort();
  final request = TranscribeRequest(
    wavPath: wavPath,
    models: models,
    hotwords: hotwords,
    numThreads: numThreads,
    replyPort: replyPort.sendPort,
  );
  final isolate = await Isolate.spawn(_worker, request);
  final completer = Completer<List<TranscriptSegment>>();

  void handle(Object? msg) {
    if (msg is List && msg.isNotEmpty && msg[0] == 'progress') {
      onProgress?.call(msg[1] as String, (msg[2] as num).toDouble());
    } else if (msg is Map) {
      if (msg['done'] == true) {
        final list = (msg['segments'] as List? ?? const [])
            .map((e) => TranscriptSegment(
                  speaker: (e['speaker'] as num).toInt(),
                  startMs: (e['startMs'] as num).toDouble(),
                  endMs: (e['endMs'] as num).toDouble(),
                  text: e['text'] as String? ?? '',
                ))
            .toList();
        completer.complete(list);
      } else if (msg['error'] != null) {
        completer.completeError(StateError(msg['error'] as String));
      }
    }
  }

  replyPort.listen(handle);
  try {
    return await completer.future;
  } finally {
    await replyPort.close();
    isolate.kill(priority: Isolate.immediate);
  }
}

/// 后台 isolate 入口：初始化绑定 → 加载模型 → 转写 → 返回结果。
void _worker(TranscribeRequest req) {
  final port = req.replyPort;
  try {
    so.initBindings();

    final wave = so.readWave(req.wavPath);
    if (wave.samples.isEmpty || wave.sampleRate == 0) {
      throw StateError('无法读取音频：${req.wavPath}');
    }
    var samples = wave.samples;
    // VAD 与模型均为 16kHz，非 16kHz 时线性重采样。
    if (wave.sampleRate != 16000) {
      samples = _resample(samples, wave.sampleRate, 16000);
    }

    _progress(port, '加载模型', 0.0);

    // 说话人分离模型（Pyannote 分割 + NeMo 嵌入）。
    final diarizer = so.OfflineSpeakerDiarization(
      so.OfflineSpeakerDiarizationConfig(
        segmentation: so.OfflineSpeakerSegmentationModelConfig(
          pyannote: so.OfflineSpeakerSegmentationPyannoteModelConfig(
            model: req.models.segmentation,
          ),
          numThreads: req.numThreads,
        ),
        embedding: so.SpeakerEmbeddingExtractorConfig(
          model: req.models.embedding,
          numThreads: req.numThreads,
        ),
        clustering: so.FastClusteringConfig(numClusters: -1),
      ),
    );

    // VAD 切分语音段。
    final vad = so.VoiceActivityDetector(
      so.VadModelConfig(
        sampleRate: 16000,
        sileroVad: so.SileroVadModelConfig(model: req.models.vad),
        numThreads: req.numThreads,
      ),
    );

    // Paraformer 识别器（热词文件在本地已写好）。
    final hotwordsFile =
        req.hotwords.isEmpty ? '' : _writeHotwordsTmp(req.hotwords);
    final recognizer = so.OfflineRecognizer(
      so.OfflineRecognizerConfig(
        model: so.OfflineModelConfig(
          paraformer: so.OfflineParaformerModelConfig(model: req.models.asr),
          tokens: req.models.tokens,
          numThreads: req.numThreads,
          provider: 'cpu',
        ),
        hotwordsFile: hotwordsFile,
        hotwordsScore: 1.5,
      ),
    );

    _progress(port, '切分语音', 0.1);

    // VAD 切段。
    final vadSegments = <_VadSeg>[];
    vad.acceptWaveform(samples);
    while (!vad.isEmpty()) {
      final seg = vad.front();
      if (seg.samples.isNotEmpty) {
        vadSegments.add(_VadSeg(
          startSample: seg.start,
          samples: seg.samples,
        ));
      }
      vad.pop();
    }
    vad.free();
    vadSegments.sort((a, b) => a.startSample.compareTo(b.startSample));

    // 逐段转写。
    final raw = <_RawSeg>[];
    for (var i = 0; i < vadSegments.length; i++) {
      final s = vadSegments[i];
      final stream = recognizer.createStream();
      stream.acceptWaveform(samples: s.samples, sampleRate: 16000);
      recognizer.decode(stream);
      final result = recognizer.getResult(stream);
      stream.free();
      final text = result.text.trim();
      if (text.isNotEmpty) {
        raw.add(_RawSeg(
          startSample: s.startSample,
          endSample: s.startSample + s.samples.length,
          text: text,
        ));
      }
      final frac = 0.1 + 0.7 * ((i + 1) / vadSegments.length);
      _progress(port, '转写中 ${i + 1}/${vadSegments.length}', frac);
    }
    recognizer.free();
    vadSegments.clear();

    // 说话人分离（整段音频）。
    _progress(port, '说话人分离', 0.85);
    final spkSegments = <_SpkSeg>[];
    try {
      final segs = diarizer.process(samples: samples);
      for (final s in segs) {
        spkSegments.add(_SpkSeg(
          startMs: s.start * 1000,
          endMs: s.end * 1000,
          speaker: s.speaker,
        ));
      }
    } finally {
      diarizer.free();
    }

    // 按说话人对齐合并。
    final merged = _merge(raw, spkSegments, sampleRate: 16000);
    _progress(port, '完成', 1.0);

    port.send({
      'done': true,
      'segments': merged
          .map((s) => {
                'speaker': s.speaker,
                'startMs': s.startMs,
                'endMs': s.endMs,
                'text': s.text,
              })
          .toList(),
    });
  } catch (e, st) {
    port.send({'error': '$e\n$st'});
  }
}

/// 线性重采样到目标采样率。
Float32List _resample(Float32List src, int srcRate, int dstRate) {
  if (srcRate == dstRate) return src;
  final ratio = dstRate / srcRate;
  final outLen = (src.length * ratio).round();
  final out = Float32List(outLen);
  for (var i = 0; i < outLen; i++) {
    final pos = i / ratio;
    final idx = pos.floor();
    final frac = pos - idx;
    final a = src[idx.clamp(0, src.length - 1)];
    final b = src[(idx + 1).clamp(0, src.length - 1)];
    out[i] = a + (b - a) * frac;
  }
  return out;
}

/// 把热词写入临时文件，返回路径。
String _writeHotwordsTmp(List<String> hotwords) {
  final dir = Directory.systemTemp.path;
  final f =
      '$dir/sherpa_hotwords_${DateTime.now().millisecondsSinceEpoch}.txt';
  File(f).writeAsStringSync(
    hotwords.where((w) => w.trim().isNotEmpty).join('\n'),
    encoding: utf8,
  );
  return f;
}

void _progress(SendPort port, String phase, double fraction) {
  port.send(['progress', phase, fraction]);
}

// ---- 内部结构 ----
class _VadSeg {
  _VadSeg({required this.startSample, required this.samples});
  final int startSample;
  final Float32List samples;
}

class _RawSeg {
  _RawSeg({
    required this.startSample,
    required this.endSample,
    required this.text,
  });
  final int startSample;
  final int endSample;
  final String text;
}

class _SpkSeg {
  _SpkSeg({
    required this.startMs,
    required this.endMs,
    required this.speaker,
  });
  final double startMs;
  final double endMs;
  final int speaker;
}

/// 把 ASR 段按说话人时间区间对齐，合并相邻同说话人段。
List<TranscriptSegment> _merge(
  List<_RawSeg> raw,
  List<_SpkSeg> spk,
  {required int sampleRate},
) {
  if (raw.isEmpty) return const [];
  final out = <TranscriptSegment>[];
  TranscriptSegment? current;

  for (final r in raw) {
    final startMs = r.startSample * 1000 / sampleRate;
    final endMs = r.endSample * 1000 / sampleRate;
    final speaker = _speakerAt(spk, (startMs + endMs) / 2);

    if (current != null &&
        current.speaker == speaker &&
        current.endMs >= startMs - 300) {
      current = TranscriptSegment(
        speaker: current.speaker,
        startMs: current.startMs,
        endMs: endMs,
        text: current.text + r.text,
      );
    } else {
      if (current != null) out.add(current);
      current = TranscriptSegment(
        speaker: speaker,
        startMs: startMs,
        endMs: endMs,
        text: r.text,
      );
    }
  }
  if (current != null) out.add(current);
  return out;
}

/// 返回覆盖 [tMs] 毫秒时刻的说话人编号；无覆盖返回 -1。
int _speakerAt(List<_SpkSeg> spk, double tMs) {
  for (final s in spk) {
    if (tMs >= s.startMs && tMs < s.endMs) return s.speaker;
  }
  return -1;
}
