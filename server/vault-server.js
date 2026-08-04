// 云端保险柜服务端（极简）。
// 用法：
//   AUTH_TOKEN=你的管理密钥 node vault-server.js
// 端点：
//   PUT /vault/{id}  上传/覆盖保险柜 id（1~100）的数据
//   GET /vault/{id}  下载保险柜 id 的数据
//   GET /health      健康检查
// 数据以密文形式存盘（App 侧已用用户密钥加密，服务器看不到内容）。
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 8741;
const AUTH_TOKEN = process.env.AUTH_TOKEN || '';
const DATA_DIR = path.join(__dirname, 'vault_data');
if (!fs.existsSync(DATA_DIR)) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
}

// 柜号合法范围。
function validId(id) {
  const n = Number(id);
  return Number.isInteger(n) && n >= 1 && n <= 100;
}

// 鉴权：配置了 AUTH_TOKEN 时校验 X-Auth-Token。
function authorized(req) {
  if (!AUTH_TOKEN) return true;
  return req.headers['x-auth-token'] === AUTH_TOKEN;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const parts = url.pathname.split('/').filter(Boolean);

  // 健康检查。
  if (url.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, vaults: 100 }));
    return;
  }

  if (!authorized(req)) {
    res.writeHead(403, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'unauthorized' }));
    return;
  }

  // /vault/{id}
  if (parts.length === 2 && parts[0] === 'vault') {
    const id = parts[1];
    if (!validId(id)) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'vault id must be 1-100' }));
      return;
    }
    const file = path.join(DATA_DIR, `${id}.bin`);

    if (req.method === 'PUT') {
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => {
        fs.writeFileSync(file, Buffer.concat(chunks));
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, id }));
      });
      req.on('error', (e) => {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: String(e) }));
      });
      return;
    }

    if (req.method === 'GET') {
      if (!fs.existsSync(file)) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'vault empty' }));
        return;
      }
      const data = fs.readFileSync(file);
      res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
      res.end(data);
      return;
    }

    if (req.method === 'DELETE') {
      if (fs.existsSync(file)) fs.unlinkSync(file);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, id }));
      return;
    }
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found' }));
});

server.listen(PORT, () => {
  console.log(`Vault server on :${PORT} (data dir: ${DATA_DIR})`);
  console.log(AUTH_TOKEN ? 'Auth enabled' : 'WARNING: no AUTH_TOKEN set, open access');
});
