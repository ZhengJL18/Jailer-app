/// 主题系统：集中定义配色，多套方案 + 明暗模式。
///
/// 用 ThemeExtension 让配色自动继承到所有 context（`context.appPalette`）。
/// 切换主题 = 换 ThemeData + ThemeExtension，全局 rebuild（避免硬编码色不更新）。
library;

import 'package:flutter/material.dart';

/// 应用调色板：一套完整配色（替代各处硬编码 Colors.x）。
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  final Color primary; // 主色（替代 teal）
  final Color onPrimary; // 主色上的文字
  final Color primaryContainer; // 主色浅底
  final Color onPrimaryContainer;
  final Color surface; // 背景/卡片
  final Color surfaceVariant; // 次要背景（assistant 气泡）
  final Color textPrimary; // 主要文本
  final Color textSecondary; // 次要文本/描述（替代 grey）
  final Color success; // 成功（绿）
  final Color danger; // 危险/删除（红）
  final Color accent; // 点缀（蓝/amber）
  final Color border; // 边框

  const AppPalette({
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.surface,
    required this.surfaceVariant,
    required this.textPrimary,
    required this.textSecondary,
    required this.success,
    required this.danger,
    required this.accent,
    required this.border,
  });

  @override
  AppPalette copyWith({
    Color? primary,
    Color? onPrimary,
    Color? primaryContainer,
    Color? onPrimaryContainer,
    Color? surface,
    Color? surfaceVariant,
    Color? textPrimary,
    Color? textSecondary,
    Color? success,
    Color? danger,
    Color? accent,
    Color? border,
  }) {
    return AppPalette(
      primary: primary ?? this.primary,
      onPrimary: onPrimary ?? this.onPrimary,
      primaryContainer: primaryContainer ?? this.primaryContainer,
      onPrimaryContainer: onPrimaryContainer ?? this.onPrimaryContainer,
      surface: surface ?? this.surface,
      surfaceVariant: surfaceVariant ?? this.surfaceVariant,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      success: success ?? this.success,
      danger: danger ?? this.danger,
      accent: accent ?? this.accent,
      border: border ?? this.border,
    );
  }

  @override
  AppPalette lerp(AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      primary: Color.lerp(primary, other.primary, t)!,
      onPrimary: Color.lerp(onPrimary, other.onPrimary, t)!,
      primaryContainer:
          Color.lerp(primaryContainer, other.primaryContainer, t)!,
      onPrimaryContainer:
          Color.lerp(onPrimaryContainer, other.onPrimaryContainer, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceVariant: Color.lerp(surfaceVariant, other.surfaceVariant, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      success: Color.lerp(success, other.success, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      border: Color.lerp(border, other.border, t)!,
    );
  }
}

/// 从 ColorScheme 构建 AppPalette（保证和 ThemeData 的 scheme 一致）。
AppPalette paletteFromScheme(ColorScheme scheme, {required bool isDark}) {
  return AppPalette(
    primary: scheme.primary,
    onPrimary: scheme.onPrimary,
    primaryContainer: scheme.primaryContainer,
    onPrimaryContainer: scheme.onPrimaryContainer,
    surface: scheme.surface,
    surfaceVariant: scheme.surfaceContainerHighest,
    textPrimary: scheme.onSurface,
    textSecondary: scheme.onSurfaceVariant,
    success: isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32),
    danger: isDark ? const Color(0xFFEF9A9A) : const Color(0xFFC62828),
    accent: isDark ? const Color(0xFF90CAF9) : const Color(0xFF1565C0),
    border: scheme.outlineVariant,
  );
}

/// 一套完整主题（亮 + 暗）。
class AppThemeSpec {
  final String id;
  final String name;
  final Color lightSeed;
  final Color darkSeed;

  const AppThemeSpec({
    required this.id,
    required this.name,
    required this.lightSeed,
    required this.darkSeed,
  });

  ThemeData lightTheme() => _build(lightSeed, isDark: false);
  ThemeData darkTheme() => _build(darkSeed, isDark: true);

  ThemeData _build(Color seed, {required bool isDark}) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: isDark ? Brightness.dark : Brightness.light);
    final palette = paletteFromScheme(scheme, isDark: isDark);
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
    );
    return base.copyWith(
      extensions: [palette],
      scaffoldBackgroundColor: scheme.surface,
    );
  }
}

/// 内置主题方案。
const List<AppThemeSpec> builtinThemes = [
  AppThemeSpec(
    id: 'teal', name: '青绿',
    lightSeed: Color(0xFF00897B), darkSeed: Color(0xFF4DB6AC),
  ),
  AppThemeSpec(
    id: 'indigo', name: '靛蓝',
    lightSeed: Color(0xFF3F51B5), darkSeed: Color(0xFF7986CB),
  ),
  AppThemeSpec(
    id: 'warm', name: '暖橙',
    lightSeed: Color(0xFFE65100), darkSeed: Color(0xFFFFB74D),
  ),
  AppThemeSpec(
    id: 'violet', name: '紫罗兰',
    lightSeed: Color(0xFF7B1FA2), darkSeed: Color(0xFFBA68C8),
  ),
  AppThemeSpec(
    id: 'rose', name: '玫瑰',
    lightSeed: Color(0xFFC2185B), darkSeed: Color(0xFFF06292),
  ),
];

AppThemeSpec findTheme(String id) {
  for (final t in builtinThemes) {
    if (t.id == id) return t;
  }
  return builtinThemes.first;
}
