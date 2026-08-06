// 从 printnotes build_markdown.dart 移植，去掉 provider 耦合：
// theme_provider.codeHighlight / settings_provider.useLatex / editor_config_provider.fontSize
// 改为参数注入，由上层（HermesMarkdown）提供，贴合 hermes 全局单例 + ValueNotifier 模式。
import 'package:flutter/material.dart';

import 'package:flutter_highlight/theme_map.dart';
import 'package:flutter_highlight/themes/a11y-light.dart';
import 'package:flutter_highlight/themes/a11y-dark.dart';

import 'rendering/code_wrapper.dart';
import 'rendering/custom_img_builder.dart';
import 'rendering/custom_node.dart';
import 'rendering/latex.dart';
import 'rendering/wiki_link.dart';
import 'rendering/highlighter.dart';
import 'rendering/underline.dart';
import 'rendering/note_tags.dart';
import 'rendering/strikethrough.dart';
import 'rendering/subscript.dart';
import 'rendering/superscript.dart';

import 'link_handler.dart';

/// 渲染配置参数（原 provider 读取项，改注入）。
class MarkdownRenderOptions {
  final String codeHighlight; // flutter_highlight theme_map key
  final bool useLatex;
  final double fontSize;
  final Color? textColor;
  final bool hideCodeButtons;
  final String? imageRoot; // 本地图片搜索根目录（笔记库根）
  final Future<void> Function(String url)? onLinkTap; // 链接点击（覆盖默认）
  final bool inEditor;

  const MarkdownRenderOptions({
    this.codeHighlight = 'atom-one-dark',
    this.useLatex = true,
    this.fontSize = 16,
    this.textColor,
    this.hideCodeButtons = false,
    this.imageRoot,
    this.onLinkTap,
    this.inEditor = false,
  });
}

MarkdownConfig theMarkdownConfigs(
  BuildContext context, {
  required Uri fileUri,
  required MarkdownRenderOptions opts,
  TextEditingController? editingController,
  Future<void> Function()? onCheckboxToggle,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final config =
      isDark ? MarkdownConfig.darkConfig : MarkdownConfig.defaultConfig;
  final editorFontSize = opts.fontSize;

  codeWrapper(child, text, language) => CodeWrapperWidget(
      child, text, language,
      hideCodeButtons: opts.hideCodeButtons);

  return config.copy(configs: [
    PConfig(
      textStyle: TextStyle(
        fontSize: opts.inEditor ? editorFontSize : 16,
        color: opts.textColor,
      ),
    ),
    H1Config(
      style: TextStyle(
        fontSize: opts.inEditor ? editorFontSize + 16 : 32,
        color: opts.textColor,
      ),
    ),
    H2Config(
      style: TextStyle(
        fontSize: opts.inEditor ? editorFontSize + 8 : 24,
        color: opts.textColor,
      ),
    ),
    H3Config(
      style: TextStyle(
        fontSize: opts.inEditor ? editorFontSize + 4 : 20,
        color: opts.textColor,
      ),
    ),
    H4Config(
      style: TextStyle(
        fontSize: opts.inEditor ? editorFontSize : 16,
        color: opts.textColor,
      ),
    ),
    H5Config(
      style: TextStyle(
        fontSize: opts.inEditor ? editorFontSize : 16,
        color: opts.textColor,
      ),
    ),
    H6Config(
      style: TextStyle(
        fontSize: opts.inEditor ? editorFontSize : 16,
        color: opts.textColor,
      ),
    ),
    ListConfig(marginLeft: editorFontSize * 1.5),
    // pub 包 CheckBoxConfig 只有 builder 参数（printnotes 拷贝版的 size/onToggle
    // 是它 fork 加的，pub 版不支持）；任务勾选交互走引擎默认渲染。
    const CheckBoxConfig(),
    TableConfig(
      wrapper: (table) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: table,
      ),
    ),
    HrConfig(
      height: 2,
      color: opts.textColor ??
          Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2),
    ),
    BlockquoteConfig(
      textColor: opts.textColor ??
          Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8),
      sideColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
    ),
    ImgConfig(
      builder: (url, attributes) => CustomImgBuilder(
        url,
        fileUri,
        attributes,
        imageRoot: opts.imageRoot ?? '',
        fontSize: opts.fontSize,
      ),
    ),
    LinkConfig(onTap: (url) => _handleLinkTap(context, url, opts)),
    WikiLinkConfig(onTap: (url) => _handleLinkTap(context, url, opts)),
    PreConfig().copy(
      theme: themeMap[opts.codeHighlight] ??
          (isDark ? a11yDarkTheme : a11yLightTheme),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          width: 1,
          color: Theme.of(context)
              .colorScheme
              .onSurface
              .withValues(alpha: 0.2),
        ),
      ),
      wrapper: codeWrapper,
      textStyle: TextStyle(fontSize: opts.inEditor ? editorFontSize : null),
      styleNotMatched:
          TextStyle(fontSize: opts.inEditor ? editorFontSize : null),
    ),
  ]);
}

void _handleLinkTap(BuildContext context, String url, MarkdownRenderOptions opts) {
  if (opts.onLinkTap != null) {
    opts.onLinkTap!(url);
  } else {
    linkHandler(context, url);
  }
}

MarkdownGenerator theMarkdownGenerators(
  BuildContext context, {
  required MarkdownRenderOptions opts,
  double? textScale,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  SpanNodeGeneratorWithTag noteTagGenerator = SpanNodeGeneratorWithTag(
    tag: 'noteTag',
    generator: (e, config, visitor) => NoteTagNode(
      e.attributes,
      config,
      tagBackgroundColor:
          Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
      tagTextColor: isDark
          ? Theme.of(context).colorScheme.secondary
          : Theme.of(context).colorScheme.primary,
    ),
  );

  return MarkdownGenerator(
    generators: [
      if (opts.useLatex) latexGenerator,
      noteTagGenerator,
      highlighterGeneratorWithTag,
      underlineGeneratorWithTag,
      strikethroughGeneratorWithTag,
      superscriptGeneratorWithTag,
      subscriptGeneratorWithTag,
    ],
    inlineSyntaxList: [
      if (opts.useLatex) LatexSyntax(),
      NoteTagSyntax(),
      WikiLinkSyntax(),
      HighlighterSyntax(),
      UnderlineSyntax(),
      StrikethroughSyntax(),
      SuperscriptSyntax(),
      SubscriptSyntax(),
    ],
    textGenerator: (node, config, visitor) =>
        CustomTextNode(node.textContent, config, visitor),
    richTextBuilder: (span) => Text.rich(
      span,
      textScaler: TextScaler.linear(textScale ?? 1),
    ),
  );
}

Widget buildMarkdownWidget(
  BuildContext context, {
  required String data,
  required MarkdownRenderOptions opts,
  Uri? fileUri,
  TocController? tocController,
  ScrollPhysics? physics,
  bool shrinkWrap = false,
  bool? selectable,
  TextEditingController? editingController,
  Future<void> Function()? onCheckboxToggle,
}) {
  return MarkdownWidget(
    data: data,
    // pub 包 markdown_widget 无 controller 字段（printnotes 拷贝版才有），
    // 滚动由 tocController 或内置 AutoScrollController 驱动。
    tocController: tocController,
    physics: physics,
    shrinkWrap: shrinkWrap,
    selectable: selectable ?? true,
    config: theMarkdownConfigs(
      context,
      fileUri: fileUri ?? Uri.file(''),
      opts: opts,
      editingController: editingController,
      onCheckboxToggle: onCheckboxToggle,
    ),
    markdownGenerator: theMarkdownGenerators(context, opts: opts),
  );
}
