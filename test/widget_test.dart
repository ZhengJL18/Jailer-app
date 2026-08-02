// 轻量 smoke test —— 不 pump 整个 App（MIX 血泪教训：pump 整个 App 会触发
// 无限动画卡死 CI）。只测配置模型的纯逻辑。

import 'package:flutter_test/flutter_test.dart';
import 'package:jailer/config/jailer_config.dart';

void main() {
  test('vendor 模型预设非空', () {
    expect(vendorModels['deepseek'], isNotEmpty);
    expect(vendorModels['zai'], isNotEmpty);
    expect(vendorLabels['deepseek'], 'DeepSeek');
  });

  test('JailerConfig 缺 key 不完整', () {
    const config = JailerConfig(
      vendorId: 'deepseek',
      model: 'deepseek-chat',
      apiKey: '',
      baseUrl: '',
    );
    expect(config.isComplete, isFalse);
  });
}
