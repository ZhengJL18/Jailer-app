import 'package:flutter/foundation.dart';
import 'package:mix/printnotes/utils/configs/user_preference.dart';

/// 笔记渲染主题配置。
///
/// MIX 的整体明暗/配色由全局 ThemeController 驱动（MaterialApp 一层），
/// 这里只保留真正生效的 printnotes 配置：markdown 代码块高亮主题。
/// 其余 colorScheme/themeMode/动态色等曾是不生效的死配置，已随统一移除。
class ThemeProvider with ChangeNotifier {
  String _codeHighlight = '';

  String get codeHighlight => _codeHighlight;

  ThemeProvider() {
    loadPreferences();
  }

  void loadPreferences() {
    _codeHighlight = UserThemingPref.getCodeHighlight();
    notifyListeners();
  }

  void setCodeHighlight(String highlight) {
    _codeHighlight = highlight;
    UserThemingPref.setCodeHighlight(highlight);
    notifyListeners();
  }
}
