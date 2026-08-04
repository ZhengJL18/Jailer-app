/// 云端保险柜：配置云服务器 + 加密上传/下载/修改备份。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/vault_service.dart';

class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  final _serverController = TextEditingController();
  final _tokenController = TextEditingController();
  final _secretController = TextEditingController();
  int _vaultId = 1;
  bool _loading = true;
  bool _busy = false;
  String? _msg;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _serverController.dispose();
    _tokenController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cfg = await loadVaultConfig();
    if (!mounted) return;
    setState(() {
      if (cfg != null) {
        _serverController.text = cfg.serverUrl;
        _tokenController.text = cfg.serverToken ?? '';
        _secretController.text = cfg.secret;
        _vaultId = cfg.vaultId;
      } else {
        // 默认用官方服务器地址。
        _serverController.text = officialVaultUrl;
      }
      _loading = false;
    });
  }

  VaultConfig? _buildConfig() {
    final url = _serverController.text.trim().replaceAll(RegExp(r'/+$'), '');
    final secret = _secretController.text.trim();
    if (url.isEmpty || secret.isEmpty) {
      _setMsg('请填写服务器地址和密钥');
      return null;
    }
    return VaultConfig(
      serverUrl: url,
      vaultId: _vaultId,
      secret: secret,
      serverToken: _tokenController.text.trim().isEmpty
          ? null
          : _tokenController.text.trim(),
    );
  }

  void _setMsg(String m) {
    if (!mounted) return;
    setState(() => _msg = m);
  }

  Future<void> _saveConfig(VaultConfig cfg) async {
    await saveVaultConfig(cfg);
  }

  Future<void> _upload() async {
    final cfg = _buildConfig();
    if (cfg == null) return;
    setState(() {
      _busy = true;
      _msg = '打包并加密中…';
    });
    try {
      final payload = await buildBackupPayload();
      final encrypted = encryptPayload(payload, cfg.secret);
      setState(() => _msg = '上传到柜号 ${cfg.vaultId}…');
      await uploadBackup(cfg, encrypted);
      await _saveConfig(cfg);
      _setMsg('✓ 备份已上传到柜号 ${cfg.vaultId}（${encrypted.length} 字节，已加密）');
    } catch (e) {
      _setMsg('✗ 上传失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download() async {
    final cfg = _buildConfig();
    if (cfg == null) return;
    setState(() {
      _busy = true;
      _msg = '下载柜号 ${cfg.vaultId}…';
    });
    try {
      final encrypted = await downloadBackup(cfg);
      setState(() => _msg = '解密中…');
      final payload = decryptPayload(encrypted, cfg.secret);
      await _restorePayload(payload);
      await _saveConfig(cfg);
      _setMsg('✓ 已从柜号 ${cfg.vaultId} 恢复备份');
    } on FormatException {
      _setMsg('✗ 解密失败：密钥错误或数据损坏');
    } catch (e) {
      _setMsg('✗ 下载失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restorePayload(Map<String, dynamic> payload) async {
    final dir = await _getDocsDir();
    // 恢复 state.db。
    final dbB64 = payload['state_db'];
    if (dbB64 is String) {
      final bytes = base64Decode(dbB64);
      await File('${dir.path}/state.db').writeAsBytes(bytes);
    }
    // 恢复文件（记忆/技能）。
    final files = payload['files'];
    if (files is Map<String, dynamic>) {
      for (final entry in files.entries) {
        final relPath = entry.key;
        final content = entry.value;
        if (content is! String) continue;
        // 安全：只允许 documents 内相对路径，防路径穿越。
        final target = File('${dir.path}/$relPath');
        if (!target.path.startsWith(dir.path)) continue;
        await target.create(recursive: true);
        await target.writeAsString(content);
      }
    }
  }

  Future<Directory> _getDocsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(docs.path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('云端保险柜')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Hermes 官方云保险柜：备份用你的密钥 AES 加密，'
                          '服务器只存密文，看不到内容。柜号（1~100）是存储槽位。'
                          '服务器地址默认官方，可改成自建服务器。',
                          style: TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _serverController,
                          decoration: const InputDecoration(
                            labelText: '服务器地址',
                            hintText: 'https://your-server.com:8741',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _tokenController,
                                decoration: const InputDecoration(
                                  labelText: '服务器 Token（可选）',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 110,
                              child: InputDecorator(
                                decoration: const InputDecoration(
                                  labelText: '柜号',
                                  border: OutlineInputBorder(),
                                ),
                                child: DropdownButton<int>(
                                  value: _vaultId,
                                  isDense: true,
                                  underline: const SizedBox.shrink(),
                                  items: [
                                    for (var i = 1; i <= 100; i++)
                                      DropdownMenuItem(
                                          value: i, child: Text('$i')),
                                  ],
                                  onChanged: (v) =>
                                      setState(() => _vaultId = v ?? 1),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _secretController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: '保险柜密钥',
                            hintText: '自设密钥，务必记住',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (_msg != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(_msg!,
                                style: const TextStyle(fontSize: 12)),
                          ),
                        if (_busy) const LinearProgressIndicator(),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _busy ? null : _upload,
                                icon: const Icon(Icons.upload),
                                label: const Text('上传备份'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _busy ? null : _download,
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.teal,
                                ),
                                icon: const Icon(Icons.download),
                                label: const Text('下载恢复'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: _busy ? null : () async {
                            final cfg = _buildConfig();
                            if (cfg == null) return;
                            setState(() {
                              _busy = true;
                              _msg = '上传覆盖柜号 ${cfg.vaultId}…';
                            });
                            try {
                              final payload = await buildBackupPayload();
                              final encrypted =
                                  encryptPayload(payload, cfg.secret);
                              await uploadBackup(cfg, encrypted);
                              await _saveConfig(cfg);
                              _setMsg('✓ 已覆盖柜号 ${cfg.vaultId} 的备份');
                            } catch (e) {
                              _setMsg('✗ 覆盖失败：$e');
                            } finally {
                              if (mounted) setState(() => _busy = false);
                            }
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('修改（覆盖）现有备份'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
