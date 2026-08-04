// 云端保险柜服务端 v2（账号体系）。
//
// 用法：node vault-server.js
// 端点：
//   POST /auth/register  {name, password}  注册（保险柜名唯一）
//   POST /auth/login     {name, password}  登录 → 返回 token
//   PUT  /vault          {token, data}     上传加密数据到该账号
//   GET  /vault?token=xxx                   下载该账号的加密数据
//   GET  /health                            健康检查
//
// 数据以密文存盘（App 侧用用户密钥加密，服务器只存密文）。密码用 scrypt
// 哈希存储，服务器不知道明文密码。
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = process.env.PORT || 8741;
const DATA_DIR = path.join(__dirname, 'vault_data');
const USERS_FILE = path.join(DATA_DIR, 'users.json');

if (!fs.existsSync(DATA_DIR)) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
}
if (!fs.existsSync(USERS_FILE)) {
  fs.writeFileSync(USERS_FILE, '{}');
}

function loadUsers() {
  try {
    return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'));
  } catch (_) {
    return {};
  }
}

function saveUsers(users) {
  fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2));
}

// 会话 token → 用户名（内存，重启失效，可接受）。
const sessions = new Map();

function hashPassword(password, salt) {
  return crypto.scryptSync(password, salt, 64).toString('hex');
}

function sendJson(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(obj));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const parts = url.pathname.split('/').filter(Boolean);

  if (url.pathname === '/health') {
    sendJson(res, 200, { ok: true });
    return;
  }

  // 注册。
  if (parts.length === 2 && parts[0] === 'auth' && parts[1] === 'register' && req.method === 'POST') {
    try {
      const body = JSON.parse((await readBody(req)).toString());
      const name = String(body.name || '').trim().toLowerCase();
      const password = String(body.password || '');
      if (!/^[a-z0-9_-]{2,32}$/.test(name)) {
        sendJson(res, 400, { error: '保险柜名需 2-32 位字母/数字/_-' });
        return;
      }
      if (password.length < 6) {
        sendJson(res, 400, { error: '密码至少 6 位' });
        return;
      }
      const users = loadUsers();
      if (users[name]) {
        sendJson(res, 409, { error: '保险柜名已被占用' });
        return;
      }
      const salt = crypto.randomBytes(16).toString('hex');
      users[name] = {
        salt,
        hash: hashPassword(password, salt),
        createdAt: Date.now(),
      };
      saveUsers(users);
      const token = crypto.randomBytes(24).toString('hex');
      sessions.set(token, name);
      sendJson(res, 200, { ok: true, name, token });
    } catch (e) {
      sendJson(res, 500, { error: String(e) });
    }
    return;
  }

  // 登录。
  if (parts.length === 2 && parts[0] === 'auth' && parts[1] === 'login' && req.method === 'POST') {
    try {
      const body = JSON.parse((await readBody(req)).toString());
      const name = String(body.name || '').trim().toLowerCase();
      const password = String(body.password || '');
      const users = loadUsers();
      const user = users[name];
      if (!user || hashPassword(password, user.salt) !== user.hash) {
        sendJson(res, 401, { error: '保险柜名或密码错误' });
        return;
      }
      const token = crypto.randomBytes(24).toString('hex');
      sessions.set(token, name);
      sendJson(res, 200, { ok: true, name, token });
    } catch (e) {
      sendJson(res, 500, { error: String(e) });
    }
    return;
  }

  // 校验 token → 用户名。
  if (parts.length === 1 && parts[0] === 'vault') {
    // token 从 header X-Auth-Token 或 query。
    const token = (req.headers['x-auth-token'] || url.searchParams.get('token') || '').toString();
    const name = sessions.get(token);
    if (!name) {
      sendJson(res, 401, { error: '未登录或会话过期' });
      return;
    }
    const file = path.join(DATA_DIR, `vault_${name}.bin`);

    if (req.method === 'PUT') {
      try {
        const data = await readBody(req);
        fs.writeFileSync(file, data);
        sendJson(res, 200, { ok: true, name, size: data.length });
      } catch (e) {
        sendJson(res, 500, { error: String(e) });
      }
      return;
    }

    if (req.method === 'GET') {
      if (!fs.existsSync(file)) {
        sendJson(res, 404, { error: '该保险柜还没有备份' });
        return;
      }
      const data = fs.readFileSync(file);
      res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
      res.end(data);
      return;
    }
  }

  sendJson(res, 404, { error: 'not found' });
});

server.listen(PORT, () => {
  console.log(`Vault server v2 on :${PORT} (data dir: ${DATA_DIR})`);
});
