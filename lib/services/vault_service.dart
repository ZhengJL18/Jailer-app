/// 云端保险柜：用用户密钥 AES 加密备份包，上传/下载到云服务器。
///
/// - 用户自设密钥 → PBKDF2 派生 AES 密钥 → 加密数据（服务器只存密文）。
/// - 柜号（1~100）作为服务器上的存储槽位。
/// - 服务器极简：POST/GET /vault/{id}，只存不解析内容。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hermes 官方云保险柜地址。
/// nginx 反代到 8741，App 直接走 80 端口（无需安全组放行 8741）。
/// 用户可覆盖（支持自建服务器）。
const String officialVaultUrl = 'http://43.139.179.58';

/// 官方服务器的管理 token（App 内置，官方服务器有效）。
/// 用户配置 serverToken 时优先用用户的；未配置且连官方服务器时用此 token。
const String officialVaultToken = '8abcf78d83529f4751718168f2dcabcd';

/// 保险柜配置（服务器 + 柜号 + 密钥）。
class VaultConfig {
  final String serverUrl; // 如 https://your-server.com
  final int vaultId; // 1~100
  final String secret; // 用户密钥
  final String? serverToken; // 服务器管理 token（可选）

  const VaultConfig({
    required this.serverUrl,
    required this.vaultId,
    required this.secret,
    this.serverToken,
  });

  bool get isComplete => serverUrl.isNotEmpty && secret.isNotEmpty;
}

/// 读取保险柜配置。
Future<VaultConfig?> loadVaultConfig() async {
  final prefs = await SharedPreferences.getInstance();
  final url = prefs.getString('vault_server') ?? '';
  final id = prefs.getInt('vault_id') ?? 0;
  final secret = prefs.getString('vault_secret') ?? '';
  if (url.isEmpty || secret.isEmpty) {
    return null;
  }
  return VaultConfig(
    serverUrl: url,
    vaultId: id,
    secret: secret,
    serverToken: prefs.getString('vault_token'),
  );
}

/// 保存保险柜配置。
Future<void> saveVaultConfig(VaultConfig cfg) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('vault_server', cfg.serverUrl);
  await prefs.setInt('vault_id', cfg.vaultId);
  await prefs.setString('vault_secret', cfg.secret);
  if (cfg.serverToken != null) {
    await prefs.setString('vault_token', cfg.serverToken!);
  }
}

/// 把 App 数据打包成 JSON 备份（state.db + 记忆 + 技能 + 配置）。
///
/// [skipDb] 测试用：跳过数据库读取。
Future<Map<String, dynamic>> buildBackupPayload() async {
  final payload = <String, dynamic>{};
  final dir = await getApplicationDocumentsDirectory();
  final now = DateTime.now().toIso8601String();

  // 会话库（state.db）→ base64。
  final dbFile = File('${dir.path}/state.db');
  if (dbFile.existsSync()) {
    final bytes = await dbFile.readAsBytes();
    payload['state_db'] = base64Encode(bytes);
  }

  // 记忆 + 技能：扫描 documents 下相关文件。
  final files = <String, String>{};
  for (final entry in Directory(dir.path).listSync(recursive: true)) {
    if (entry is! File) continue;
    final name = entry.path.split('/').last;
    // 记忆 / 技能 / 配置类文本文件。
    if (name.endsWith('.md') ||
        name.endsWith('.yaml') ||
        name.endsWith('.yml')) {
      try {
        files[entry.path.substring(dir.path.length + 1)] =
            await entry.readAsString();
      } catch (_) {}
    }
  }
  payload['files'] = files;
  payload['backed_up_at'] = now;

  return payload;
}

/// AES-256-CBC 加密数据（PBKDF2 派生密钥，随机 IV）。
Uint8List encryptPayload(Map<String, dynamic> payload, String secret) {
  final plaintext = utf8.encode(jsonEncode(payload));

  // 派生 32 字节密钥 + 16 字节 IV。
  final random = Random.secure();
  final salt = Uint8List(16);
  for (var i = 0; i < salt.length; i++) {
    salt[i] = random.nextInt(256);
  }
  final iv = Uint8List(16);
  for (var i = 0; i < iv.length; i++) {
    iv[i] = random.nextInt(256);
  }

  final key = _deriveKey(secret, salt);
  final cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(key), iv));

  // PKCS7 填充。
  final blockSize = 16;
  final paddedLen = ((plaintext.length / blockSize).ceil()) * blockSize;
  final padded = Uint8List(paddedLen)..setAll(0, plaintext);
  for (var i = plaintext.length; i < paddedLen; i++) {
    padded[i] = (blockSize - plaintext.length % blockSize) & 0xff;
  }

  final out = Uint8List(paddedLen);
  var offset = 0;
  while (offset < paddedLen) {
    offset += cipher.processBlock(padded, offset, out, offset);
  }

  // 格式：[salt(16) | iv(16) | ciphertext]。
  final result = Uint8List(16 + 16 + out.length)
    ..setAll(0, salt)
    ..setAll(16, iv)
    ..setAll(32, out);
  return result;
}

/// AES-256-CBC 解密。
Map<String, dynamic> decryptPayload(Uint8List data, String secret) {
  if (data.length < 32) {
    throw const FormatException('加密数据损坏');
  }
  final salt = Uint8List.sublistView(data, 0, 16);
  final iv = Uint8List.sublistView(data, 16, 32);
  final ciphertext = Uint8List.sublistView(data, 32);

  final key = _deriveKey(secret, salt);
  final cipher = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(key), iv));

  final out = Uint8List(ciphertext.length);
  var offset = 0;
  while (offset + 16 <= ciphertext.length) {
    offset += cipher.processBlock(ciphertext, offset, out, offset);
  }

  // 去 PKCS7 填充。
  var padLen = out.isNotEmpty ? out[out.length - 1] : 0;
  if (padLen < 1 || padLen > 16 || padLen > out.length) {
    padLen = 0;
  }
  final plaintext = utf8.decode(out.sublist(0, out.length - padLen));
  return jsonDecode(plaintext) as Map<String, dynamic>;
}

/// PBKDF2-HMAC-SHA256 派生密钥。
Uint8List _deriveKey(String secret, Uint8List salt) {
  final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, 60000, 32));
  return pbkdf2.process(utf8.encode(secret));
}

/// 有效 token：用户配置优先，连官方服务器时用内置官方 token。
String? _effectiveToken(VaultConfig cfg) {
  if (cfg.serverToken != null && cfg.serverToken!.isNotEmpty) {
    return cfg.serverToken;
  }
  if (cfg.serverUrl == officialVaultUrl) {
    return officialVaultToken;
  }
  return null;
}

/// 上传备份（覆盖柜号对应数据）。
Future<void> uploadBackup(VaultConfig cfg, Uint8List encrypted) async {
  final uri = Uri.parse('${cfg.serverUrl}/vault/${cfg.vaultId}');
  final token = _effectiveToken(cfg);
  final resp = await http
      .put(
        uri,
        headers: {
          'Content-Type': 'application/octet-stream',
          'X-Auth-Token': ?token,
        },
        body: encrypted,

      )
      .timeout(const Duration(seconds: 30));
  if (resp.statusCode != 200) {
    throw HttpException('上传失败：HTTP ${resp.statusCode} ${resp.body}');
  }
}

/// 下载备份（读取柜号对应密文）。
Future<Uint8List> downloadBackup(VaultConfig cfg) async {
  final uri = Uri.parse('${cfg.serverUrl}/vault/${cfg.vaultId}');
  final token = _effectiveToken(cfg);
  final resp = await http
      .get(
        uri,
        headers: {
          'X-Auth-Token': ?token,
        },
      )
      .timeout(const Duration(seconds: 30));
  if (resp.statusCode == 404) {
    throw HttpException('柜号 ${cfg.vaultId} 还没有备份');
  }
  if (resp.statusCode != 200) {
    throw HttpException('下载失败：HTTP ${resp.statusCode} ${resp.body}');
  }
  return resp.bodyBytes;
}
