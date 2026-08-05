/// 课堂录音服务（record 插件封装）。
///
/// 统一录制 16kHz 单声道 WAV，直接满足 sherpa-onnx 的输入要求。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// 录音控制器：负责开始/停止，并给出最终 WAV 路径。
class RecordingService {
  final AudioRecorder _recorder = AudioRecorder();

  /// 是否正在录音。
  bool get isRecording => _recorder.isRecording();

  /// 开始录音，返回即将写入的 wav 路径。
  Future<String> start() async {
    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final path = p.join(dir.path, 'recordings', 'rec_$ts.wav');
    // Windows 平台 record 用 wavPCM；其余用 wav。两者都输出 16k mono WAV。
    await _recorder.start(
      RecordConfig(
        encoder: Platform.isWindows
            ? AudioEncoder.wavPCM
            : AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    return path;
  }

  /// 停止录音，返回 wav 路径。
  Future<String> stop() async {
    if (await _recorder.hasPermission()) {
      return await _recorder.stop();
    }
    return '';
  }

  /// 取消录音（丢弃文件）。
  Future<void> cancel() async {
    if (_recorder.isRecording()) {
      await _recorder.cancel();
    }
  }

  /// 录音过程中的峰值（用于波形/电平显示，0~1）。
  Future<double> currentPeak() async {
    try {
      return await _recorder.getAmplitude().then((a) => a.current);
    } catch (_) {
      return 0;
    }
  }
}
