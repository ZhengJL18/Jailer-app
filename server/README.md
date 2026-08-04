# 云端保险柜服务端

Hermes App 的「云端保险柜」用的极简存储服务。App 把数据用你自己的密钥
AES 加密后上传到这里，服务器只存密文，看不到内容。

## 部署到云服务器

### 1. 上传脚本

把 `vault-server.js` 放到服务器，比如 `/opt/vault/`。

### 2. 安装 Node（如果没有）

```bash
# Debian/Ubuntu
sudo apt update && sudo apt install -y nodejs
# 或装 Node 18+ 版本管理器
```

### 3. 启动服务

```bash
cd /opt/vault
AUTH_TOKEN=你的管理密钥 PORT=8741 node vault-server.js
```

- `AUTH_TOKEN`：访问保险柜需要带的 token（不设则任何人可读写，不安全）
- `PORT`：服务端口，默认 8741

建议用 `nohup` 或 systemd 让它常驻：

```bash
nohup env AUTH_TOKEN=xxx PORT=8741 node vault-server.js > vault.log 2>&1 &
```

### 4. 开放端口（防火墙/安全组）

- 云服务商安全组：放行 TCP 8741（或你选的端口）
- 如果服务器有防火墙：`sudo ufw allow 8741`

### 5. 建议加 HTTPS

App 需要能访问。有域名的话用 Caddy/Nginx 反代加 HTTPS：

```bash
# Caddy 一行
your-domain.com:8741 {
    reverse_proxy 127.0.0.1:8741
}
```

没域名也可以直接用 `http://服务器IP:8741`（App 支持 http，但明文传输密钥，
自用且内网/受信网络可接受）。

## 测试

```bash
curl http://服务器IP:8741/health
# → {"ok":true,"vaults":100}

# 上传（id=5）
curl -X PUT -H "X-Auth-Token: xxx" --data-binary @test.bin http://服务器IP:8741/vault/5

# 下载
curl http://服务器IP:8741/vault/5
```

## 在 App 里配置

手机 Hermes → 设置 → 云端保险柜：
- 服务器地址：`https://你的域名:8741` 或 `http://服务器IP:8741`
- 柜号：1~100 任选一个（记住它）
- 保险柜密钥：你自己设的密码（务必记住，忘记无法找回）
- 服务器 Token：部署时设的 AUTH_TOKEN（可选，不设可留空）

点「上传备份」存档，换设备后点「下载恢复」。
