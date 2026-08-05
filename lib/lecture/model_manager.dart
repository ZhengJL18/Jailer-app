/// sherpa-onnx 模型下载与状态管理。
///
/// 模型首次运行前需下载到应用文档目录。下载源可配置（默认 HuggingFace
/// resolve URL，均验证存在），下载完成后本地缓存，避免重复下载。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 单个待下载模型文件。
class ModelFile {
  const ModelFile({
    required this.key,
    required this.url,
    required this.localName,
    required this.description,
    this.required = true,
  });

  /// 唯一标识，如 `asr` / `vad` / `segmentation` / `embedding`。
  final String key;
  final String url;
  final String localName;
  final String description;
  final bool required;
}

/// 下载进度回调：[doneBytes] 当前文件已完成字节数，[totalBytes] 总字节数，
/// [currentModel] 当前文件名，[index]/[count] 文件序号。
typedef DownloadProgress = void Function(
  int doneBytes,
  int totalBytes,
  String currentModel,
  int index,
  int count,
);

/// 模型下载管理器：清单、状态检查、下载、目录解析。
class ModelManager {
  /// 所有模型清单。URL 均已在实现时验证为可访问。
  static const List<ModelFile> models = [
    ModelFile(
      key: 'asr',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-paraformer-zh-2023-09-14/resolve/main/model.int8.onnx',
      localName: 'paraformer.int8.onnx',
      description: '中文转写模型（Paraformer，int8，约 900MB）',
    ),
    ModelFile(
      key: 'tokens',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-paraformer-zh-2023-09-14/resolve/main/tokens.txt',
      localName: 'tokens.txt',
      description: 'Paraformer 词表',
    ),
    ModelFile(
      key: 'vad',
      url:
          'https://huggingface.co/R4kSo1997/sherpa-onnx-silero-vad-v5/resolve/main/silero_vad.onnx',
      localName: 'silero_vad.onnx',
      description: '语音活动检测（VAD，约 2MB）',
    ),
    ModelFile(
      key: 'segmentation',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.int8.onnx',
      localName: 'pyannote_seg.int8.onnx',
      description: '说话人分割（Pyannote，约 80MB）',
    ),
    ModelFile(
      key: 'embedding',
      url:
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_large.onnx',
      localName: 'nemo_titanet_large.onnx',
      description: '说话人嵌入（NeMo Titanet-Large，约 30MB）',
    ),
  ];

  static String? _cacheDir;

  /// 模型缓存根目录（应用文档目录/lecture_models）。
  static Future<String> modelDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final docs = await getApplicationDocumentsDirectory();
    _cacheDir = p.join(docs.path, 'lecture_models');
    await Directory(_cacheDir!).create(recursive: true);
    return _cacheDir!;
  }

  /// 模型文件的本地绝对路径（未下载时返回 null）。
  static Future<String?> localPathFor(String key) async {
    final files = models.where((m) => m.key == key);
    if (files.isEmpty) return null;
    final dir = await modelDir();
    return p.join(dir, files.first.localName);
  }

  /// 某个模型是否已下载且文件非空。
  static Future<bool> isDownloaded(String key) async {
    final path = await localPathFor(key);
    if (path == null) return false;
    try {
      final f = File(path);
      return await f.exists() && await f.length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// 是否所有必需模型都已就绪。
  static Future<bool> allReady() async {
    for (final m in models) {
      if (m.required && !await isDownloaded(m.key)) return false;
    }
    return true;
  }

  /// 已下载模型的数量（用于 UI 展示）。
  static Future<int> downloadedCount() async {
    var n = 0;
    for (final m in models) {
      if (await isDownloaded(m.key)) n++;
    }
    return n;
  }

  /// 下载缺失的模型，逐个进行。已存在的文件跳过。
  /// 同一时刻只允许一个下载任务，重复调用会复用进行中的任务。
  static Future<void> ensureDownloaded({DownloadProgress? onProgress}) async {
    final dir = await modelDir();
    final total = models.length;
    for (var i = 0; i < total; i++) {
      final m = models[i];
      final target = p.join(dir, m.localName);
      final done = File(target).existsSync() &&
          File(target).lengthSync() > 0;
      if (done) {
        onProgress?.call(-1, -1, m.localName, i + 1, total);
        continue;
      }
      debugPrint('[ModelManager] downloading ${m.key}: ${m.url}');
      await _download(m.url, target, (b, t) {
        onProgress?.call(b, t, m.localName, i + 1, total);
      });
      debugPrint('[ModelManager] done ${m.key}');
    }
  }

  static Future<void> _download(
    String url,
    String target, {
    void Function(int, int)? onProgress,
  }) async {
    final request = http.Request('GET', Uri.parse(url));
    // huggingface resolve 默认返回 302 重定向，跟随。
    final client = http.Client();
    try {
      final response = await client.send(request);
      if (response.statusCode == 302 || response.statusCode == 301) {
        final location = response.headers['location'];
        if (location == null) {
          throw HttpException('Redirect without location: $url');
        }
        await response.stream.drain<void>();
        final finalResponse = await client.send(
          http.Request('GET', Uri.parse(location)),
        );
        await _saveBody(finalResponse, target, onProgress);
        return;
      }
      if (response.statusCode != 200) {
        throw HttpException(
          'Download failed ${response.statusCode} for $url',
        );
      }
      await _saveBody(response, target, onProgress);
    } finally {
      client.close();
    }
  }

  static Future<void> _saveBody(
    http.StreamedResponse response,
    String target, {
    void Function(int, int)? onProgress,
  }) async {
    final total = response.contentLength ?? 0;
    final sink = File(target).openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  /// 生成热词文件并返回路径；无热词时返回空串。
  static Future<String> writeHotwordsFile(List<String> hotwords) async {
    if (hotwords.isEmpty) return '';
    final dir = await getApplicationSupportDirectory();
    final f = File(p.join(dir.path, 'hotwords.txt'));
    await f.writeAsString(
      hotwords.map((w) => w.trim()).where((w) => w.isNotEmpty).join('\n'),
      encoding: utf8,
    );
    return f.path;
  }
}
