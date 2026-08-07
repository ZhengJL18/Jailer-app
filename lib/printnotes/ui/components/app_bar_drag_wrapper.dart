import 'package:flutter/material.dart';

// 原 printnotes 版用 window_manager（桌面拖拽），Android 直接返回 child。
// 适配为纯 Android：恒返回 child（窗口管理仅桌面需要，hermes 目标 Android）。
class AppBarDragWrapper extends StatelessWidget implements PreferredSizeWidget {
  const AppBarDragWrapper({super.key, required this.child, this.bottom = 0});

  final Widget child;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    return child;
  }

  @override
  Size get preferredSize => Size.fromHeight(kToolbarHeight + bottom);
}
