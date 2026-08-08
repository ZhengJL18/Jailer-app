import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:mix/printnotes/providers/settings_provider.dart';

import 'package:mix/printnotes/ui/screens/home/intro_screen.dart';
import 'package:mix/printnotes/ui/screens/home/notes_display.dart';
import 'package:mix/printnotes/ui/components/drawer.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  VoidCallback? _reloadCallback;

  void _handleReload(VoidCallback callback) {
    _reloadCallback = callback;
  }

  @override
  Widget build(BuildContext context) {
    return context.watch<SettingsProvider>().showIntro
        ? const IntroScreen()
        : NotesDisplay(
            key: ValueKey(context.watch<SettingsProvider>().mainDir),
            onReload: _handleReload,
            drawer: Drawer(
              backgroundColor: Theme.of(context).colorScheme.surface,
              child: DrawerView(
                reload: () {
                  if (_reloadCallback != null) {
                    _reloadCallback!();
                  }
                },
              ),
            ),
          );
  }
}
