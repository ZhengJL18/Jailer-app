# Hermes

在 Flutter 隔离墙（Android App 沙盒）内实现 agent 级能力的纯 Dart 框架。

**复刻策略**：以开源 [Hermes Agent](https://github.com/NousResearch/hermes-agent)（master）为唯一行为规范，用 Dart 逐文件重写其核心闭环。不自创工具系统。

**当前阶段**：复刻映射表（见 `docs/HERMES_MAPPING.md`）——先把"必须复刻 / 手机不可用跳过 / 适配"钉死，再按 P0→P1→P2 推进逐文件 Dart 复刻。

## 已实现能力

### 核心工具集（P0 复刻）

- **文件工具**：`read_file` / `write_file` / `patch` / `search_files`，支持「所有文件访问」权限（`MANAGE_EXTERNAL_STORAGE`）后读写公共目录（Download/Documents）
- **记忆系统**：跨会话持久记忆（`memory`），自动注入、容量上限管理
- **网络工具**：`web_search` / `web_extract`，内置 SSRF 防护（拦截解析到私有/内网地址的目标）
- **任务管理**：`todo` 待办清单
- **会话回顾**：`session_search` 检索历史会话
- **技能系统**：`skills_list` / `skill_view` / `skill_manage`

### 内置 git 支持

- 基于 git2dart（libgit2 嵌入），支持 clone / status / add / commit / pull / push
- 认证走 App 设置中的 GitHub PAT token（`github_pat_token` / `github_username`）
- 支持 SSL 证书配置（修复 clone 报 SSL certificate invalid）

### 对话体验

- Markdown 渲染（flutter_markdown）
- LaTeX 公式：行内 `$...$` / 块级 `$$...$$`，支持矩阵（bmatrix/vmatrix）、方程组（cases）、增广矩阵（mid）、行列式、下标、分数等

### 配置

- 多供应商 LLM 配置（DeepSeek / OpenAI 兼容），动态拉取模型列表
- 所有文件访问权限引导（设置页一键跳转系统授权）

## 项目结构

```
lib/
├── agent/          # Agent 核心循环
├── config/         # LLM 配置（jailer_config / providers）
├── db/             # SQLite 会话库（sessions / messages / FTS5）
├── llm/            # LLM 客户端（OpenAI 兼容 SSE 流式）
├── screens/        # 聊天 / 设置 / 历史 / 技能页面
├── services/       # 权限处理等服务
├── skills/         # 技能系统
├── tools/          # 工具实现（file / web / memory / todo / session / skills）
└── widgets/        # Markdown / LaTeX 组件
```

## 构建

```bash
flutter build apk --release
```

Android 11+ 首次使用需在设置页授予「所有文件访问」权限（`MANAGE_EXTERNAL_STORAGE`），agent 才能读写公共目录。
