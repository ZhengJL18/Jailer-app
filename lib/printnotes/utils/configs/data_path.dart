import 'dart:io';
import 'dart:convert';

import 'package:mix/printnotes/app.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:file_picker/file_picker.dart';

import 'package:mix/notes/notes_paths.dart';
import 'package:mix/printnotes/constants/constants.dart';
import 'package:mix/printnotes/utils/storage_system.dart';

class DataPath {
  static String? _selectedDirectory;
  static String get hiddenFolderPath =>
      path.join(_selectedDirectory!, '.printnotes');

  // MIX 集成：笔记库根固定为 documents/notes，与 agent 的 notes_* 工具共用
  // 同一目录。不允许改成任意目录，否则 agent 写的笔记 UI 看不到、
  // UI 编辑的笔记 agent 读不到——两个软件彻底分叉。
  static Future<void> setSelectedDirectory(String dirPath) async {
    _selectedDirectory = null;
    await selectedDirectory;
  }

  static Future<String?> get selectedDirectory async {
    if (_selectedDirectory == null) {
      final docs = (await getApplicationDocumentsDirectory()).path;
      _selectedDirectory = notesRootPath(docs);
      await Directory(_selectedDirectory!).create(recursive: true);
    }
    return _selectedDirectory;
  }

  static void addRecentFile(String path) {
    final recentList = App.localStorage.getStringList('recentFilesList') ?? [];

    final list = recentList.map((e) => jsonDecode(e)).toList();

    // Remove old entry with same path
    list.removeWhere((e) => e['path'] == path);

    // Add entry to the top of the list
    list.insert(
        0, {'path': path, 'openedAt': DateTime.now().millisecondsSinceEpoch});

    App.localStorage
        .setStringList('recentFilesList', list.map(jsonEncode).toList());
  }

  static List<String> loadRecentFiles(Duration within) {
    final recentList = App.localStorage.getStringList('recentFilesList') ?? [];
    final now = DateTime.now().millisecondsSinceEpoch;

    final List<String> validEntries = [];
    final List<String> cleanedList = <String>[];

    for (final item in recentList) {
      final entry = jsonDecode(item);
      final openedAt = entry['openedAt'] as int;
      final path = entry['path'] as String;

      // openedAt 是毫秒时间戳，对比也要用毫秒；原用 inMicroseconds 会把
      // "最近"窗口放大 1000 倍（30 分钟变 21 天）。
      final isRecent = (now - openedAt) <= within.inMilliseconds;
      final exists = File(path).existsSync();

      if (isRecent && exists) {
        validEntries.add(path);
        cleanedList.add(item);
      }
    }

    App.localStorage.setStringList('recentFilesList', cleanedList);
    return validEntries;
  }

  // Hidden app config file called .main_config.json

  static File get mainConfigFile =>
      File(path.join(hiddenFolderPath, 'main_config.json'));

  static File get toolbarConfigFile =>
      File(path.join(hiddenFolderPath, 'toolbar_config.json'));

  // Create and load contents of a config file
  static Map<String, dynamic> loadJsonConfigFile(File file) {
    if (!file.existsSync()) file.createSync(recursive: true);
    if (file.readAsStringSync().isEmpty) {
      file.writeAsStringSync('{}');
    }

    final fileString = file.readAsStringSync();
    return jsonDecode(fileString);
  }

  // Write to config file
  static void saveJsonConfigFile(
      File file, Map<String, dynamic> configData) async {
    final fileString = const JsonEncoder.withIndent('  ').convert(configData);
    file.writeAsStringSync(fileString);
  }

  // Deletes and regenerates json file
  static void deleteJsonConfigFile(File file) async {
    file.delete().then((_) => loadJsonConfigFile(file));
  }

  // Create a folder to store all the users upload images to use as a background

  // Path to folder with all the images
  static String get bgImagesFolderPath =>
      path.join(hiddenFolderPath, 'background_images');

  static Future<String?> uploadBgImage() async {
    if (!await Directory(bgImagesFolderPath).exists()) {
      await Directory(bgImagesFolderPath).create(recursive: true);
    }

    final pickedImage = await FilePicker.pickFiles(
        type: FileType.image, allowMultiple: false, withData: true);
    if (pickedImage != null) {
      final data = pickedImage.files.single.bytes!;
      final file = await File(
              path.join(bgImagesFolderPath, pickedImage.files.single.name))
          .writeAsBytes(
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      return file.path;
    }
    return null;
  }

  static Future<List<String>> getBgImages() async {
    List<String> imgList = [];
    if (!await Directory(bgImagesFolderPath).exists()) {
      await Directory(bgImagesFolderPath).create(recursive: true);
    }
    final imagesDir =
        await StorageSystem.listFolderContents(Uri.parse(bgImagesFolderPath));
    for (FileSystemEntity item in imagesDir) {
      if (allowedImageExtensions.any((ext) => item.path.endsWith(ext))) {
        imgList.add(item.path);
      }
    }
    return imgList;
  }

  static Future<void> deleteBgImage(String path) async {
    await File(path).delete();
  }
}
