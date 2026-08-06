// 从 printnotes link_handler.dart 移植，去掉 provider/storage_system 耦合：
// wiki-link 解析改为注入回调，由上层决定打开哪个笔记（hermes = 笔记库内跳转）。
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// 站内 wiki 链接处理器：给定解析出的文件名（可能含 `#header` 跳转），
/// 由上层负责在笔记库内匹配并打开。返回是否已处理。
typedef WikiLinkTapHandler = Future<bool> Function(
  BuildContext context,
  String name, {
  String? jumpToHeader,
});

/// 默认 wiki 链接处理器：未注入时不做任何事。
Future<bool> _noopWikiTap(
  BuildContext context,
  String name, {
  String? jumpToHeader,
}) async =>
    false;

WikiLinkTapHandler wikiLinkTapHandler = _noopWikiTap;

/// 解析 `name&jumpToHeader=xxx` → (name, jumpToHeader)。
(String, String?) _splitJumpToHeader(String url) {
  const marker = '&jumpToHeader=';
  final idx = url.indexOf(marker);
  if (idx == -1) return (url, null);
  var header = url.substring(idx + marker.length).trim();
  final name = url.substring(0, idx).trim();
  final pipe = header.lastIndexOf('|');
  if (pipe != -1) {
    header = header.substring(0, pipe).trim();
  }
  return (name, header.isEmpty ? null : header);
}

/// markdown 链接 / wiki 链接的统一点击入口。
Future<void> linkHandler(BuildContext context, String url) async {
  final (cleanUrl, jumpToHeader) = _splitJumpToHeader(url);
  final parsed = Uri.tryParse(cleanUrl);
  final hasScheme = parsed != null && parsed.hasScheme;

  if (hasScheme) {
    final target = parsed!;
    await launchUrl(target);
    return;
  }

  // 无 scheme = 笔记库内 wiki 链接，交上层处理。
  await wikiLinkTapHandler(
    context,
    cleanUrl,
    jumpToHeader: jumpToHeader,
  );
}
