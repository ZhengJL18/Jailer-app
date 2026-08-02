# Hermes master → Dart 复刻映射表

> **锚定版本**：`NousResearch/hermes-agent` @ `0a62610f10cc34d696b2239b2c69fa1ba0f1ca63`（main，2026-08-02 抓取）
> **目标**：用 Dart 在 Flutter 隔离墙（Android App 沙盒）内像素级复刻 Hermes 核心 agent 能力。
> **原则**：Hermes 源码是唯一行为规范，不自创工具系统；手机能用的工具优先复刻，其余留接口或跳过。

---

## 一、复刻分层总览

| 层级 | 含义 | 目标 |
|---|---|---|
| **P0** | 核心闭环：agent 主循环 + 工具协议 + 提示词 + 会话持久化 + provider | 手机端跑通一个真实 agent 任务 |
| **P1** | 增强：记忆、上下文压缩、迭代预算、checkpoint | agent 可用性提升 |
| **P2** | 手机可用工具补充 | 能力扩展 |
| **不复刻** | 手机沙盒跑不了的 / 纯平台绑定 / 纯内容 | 明确跳过或留接口 |

---

## 二、核心闭环（P0）— 逐文件深度分析

> 数据来源：子代理 A（根目录核心 + agent 主循环子集）

<!-- 待填充 -->

---

## 三、工具系统（P0 手机可用 + P2 其余）

> 数据来源：子代理 B（tools/ 全部，106 文件已读）

### 3.1 工具注册协议（`tools/registry.py`，932 行）— **Dart 复刻必照搬**

这是工具系统的骨架，Dart 侧必须像素级复刻：

- **注册方式**：每个工具文件顶层调用 `registry.register(name, toolset, schema, handler, check_fn, requires_env, is_async, description, emoji, max_result_size_chars, dynamic_schema_overrides, override)`。启动时 `discover_builtin_tools()` 用 AST 扫描 `tools/*.py` 检测顶层 `register()` 调用后 import 该模块（按 mtime+size 缓存），工具自注册。
- **`ToolEntry` 元数据**：name / toolset / schema / handler / check_fn / requires_env / is_async / description / emoji / max_result_size_chars / dynamic_schema_overrides
- **schema 格式**：OpenAI function-calling 字典 `{name, description, parameters: JSON Schema}`；`get_definitions(tool_names)` 包一层 `{type: "function", function: {...}}` 返回给模型，经 `schema_sanitizer` 清洗兼容各家后端。
- **handler 执行签名**：`handler(args: dict, **kwargs) -> str | dict`。普通结果必须是 JSON 字符串（`tool_result()`/`tool_error()` 辅助构造）；唯一结构化例外是 `{_multimodal: True, content: [...]}` 多模态信封。`is_async=True` 的 handler 自动桥接事件循环。`dispatch()` 捕获所有异常返回 `{error: ...}`。
- **check_fn（关键筛选闸门）**：每个工具可挂零参可用性探测（查 Docker 二进制、agent-browser CLI、API key 是否存在等），TTL 缓存 ~30s，返回 False 则该工具不出现在模型工具列表。**Android 判定 = 给每个工具写一个 `bool availability()`**。
- **toolset 概念**：工具按字符串分组（file/terminal/web/browser/delegation…），支持别名、requires_env 清单、按 toolset 查询。MCP 工具动态注册在 `mcp-<server>` 工具集下（nuke-and-repave）。插件可 `override=True` 替换内置工具。

### 3.2 工具清单（按类别，手机可用性判定）

#### 文件类
| 工具文件 | 工具名 | 职责 | 手机可用 |
|---|---|---|---|
| file_tools.py | read_file / write_file / patch / search_files | 读写、V4A 补丁、正则搜索 | ✅ 前三个纯 pathlib I/O；read_file 自动解 docx/xlsx/ipynb；search_files ⚠️ 需 rg 子进程 |
| file_operations.py | （引擎，不注册） | 路径安全、模糊匹配、patch 解析 | ✅ 引擎应复刻 |

#### 网络·Web
| 工具文件 | 工具名 | 职责 | 手机可用 |
|---|---|---|---|
| web_tools.py | web_search / web_extract | 搜索、抓网页转 markdown | ⚠️ 纯 httpx 但需 Exa/Firecrawl/Tavily key |
| url_safety / website_policy | — | SSRF 防护 / 访问策略 | ✅ 纯逻辑（引擎） |

#### 终端（❌）
terminal_tool.py（subprocess 多后端）/ process_registry.py / close_terminal / read_terminal / focus_pane / open_preview / react_to_message — 需 shell/桌面，手机无 → ❌（terminal 可留 SSH 远端接口）

#### 浏览器（❌/⚠️）
browser_tool.py（10 个工具，需 agent-browser CLI+Chromium）❌；browser_cdp_tool（CDP websocket 直通，可达端点时 ⚠️）；browser_dialog / browser_supervisor；browser_camofox（本地反检测服务）❌

#### 记忆·会话（✅ 纯状态）
| 工具文件 | 工具名 | 手机可用 |
|---|---|---|
| memory_tool.py | memory | ✅ |
| session_search_tool.py | session_search（SQLite FTS5 检索） | ✅ |
| todo_tool.py | todo | ✅ |
| kanban_tools.py | kanban_*(12) | ✅ |
| project_tools.py | project_list / create / switch | ✅ |
| clarify_tool.py | clarify | ⚠️ 需人机交互通道 |

#### 技能（✅/⚠️）
skills_tool.py / skill_manager_tool.py（skills_list/view/manage）✅；skills_hub / skills_sync* / skills_guard / skill_usage（git 同步需网络）⚠️

#### 任务·委派（✅ 进程内）
| 工具文件 | 工具名 | 手机可用 |
|---|---|---|
| delegate_tool.py | delegate_task（进程内生成子 AIAgent，**最值得复刻**） | ✅ Dart 用 isolate/协程递归 |
| async_delegation.py | —（后台委派注册表） | ✅ |
| cronjob_tools.py | cronjob（内部 JSON 调度） | ✅ |
| code_execution_tool.py | execute_code（Docker/Modal 沙箱） | ❌ 需容器 |

#### 音频·语音（❌/⚠️）
tts_tool.py（text_to_speech）⚠️ 需 key+音频设备；voice_mode / wake_word / transcription_tools / tts_streaming ❌ 麦克风+本地模型

#### 图像·视频（⚠️ 网络+key）
vision_tools.py（vision_analyze ✅ 纯 HTTP+LLM；video_analyze ⚠️ 需 ffmpeg）；image_generation_tool.py ⚠️；video_generation_tool / xai_video_tools / flux3_video_tool ⚠️；image_source.py ✅（引擎）

#### 第三方平台集成（⚠️ 需 token/网关）
discord_tool / feishu_doc / feishu_drive / homeassistant_tool / x_search_tool / yuanbao_tools / send_message_tool（引擎）— 均需各自 token 或 gateway

#### 其他
| 工具文件 | 手机可用 |
|---|---|
| mcp_tool.py | ⚠️ stdio 子进程 ❌；HTTP/SSE 服务器 ✅ |
| computer_use_tool.py | ❌ 仅桌面 |
| ~40 个辅助模块（approval / checkpoint_manager / blueprints / tool_search / tool_result_storage / schema_sanitizer / tirith_security / threat_patterns / env_probe / patch_parser / read_extract 等） | 视功能，多为引擎 |

---

## 四、外围模块（不复刻 / 留接口）

> 数据来源：子代理 C（gateway / hermes_cli / plugins / skills / cron / agent 其余文件）

### 4.1 各目录判定

| 模块 | 规模 | 职责 | 手机可用 | Dart 复刻判定 |
|---|---|---|---|---|
| gateway/ | 54 文件 | 25+ 平台常驻消息网关；session.py 核心会话层 | ⚠️ | **留接口：`session.py` 会话抽象**（SessionStore/ResetPolicy/动态上下文注入、"一次会话一个 agent"）；平台适配器与运维文件无视 |
| hermes_cli/ | 130+ 文件 | 终端 CLI 命令集；COMMAND_REGISTRY 中央命令表 | ⚠️ | **留接口：`COMMAND_REGISTRY` 单一命令定义表**（"一处定义、多端复用"）；config 简化 |
| plugins/ | 18 目录 | 可插拔生态（model-providers 30 个/context_engine/memory/browser…） | ⚠️ | **留接口：Provider ABC + Registry 发现器、单 provider 激活模式**；内容跳过 |
| skills/ | 14 目录 | 纯内容（领域技能 markdown，含 SKILL.md） | ⚠️ | 纯内容，无视；App 复用只须轻量解析 SKILL.md |
| cron/ | 7 文件 | 定时任务（60s tick + jobs.json） | ❌ | 跳过（Android 用 WorkManager 原生替代） |
| acp_adapter/ | 11 文件 | ACP JSON-RPC server（IDE 集成） | ⚠️ | 跳过 |
| mcp_serve.py | 单文件 | MCP stdio server（10 个 MCP 工具暴露会话） | ⚠️ | **留接口**（MCP 通用协议，可后置） |
| mini_swe_runner.py | — | SWE 基准跑批 | ❌ | 跳过 |
| hermes_bootstrap.py | — | Windows UTF-8 引导修复 | ❌ | 跳过（平台绑定） |
| cli.py | — | 老版终端 REPL | ❌ | 跳过 |
| apps/ | 3 目录 | Electron 桌面 UI + TS 共享库 | ⚠️ | 跳过（前端工程） |

### 4.2 agent/ 其余 ~110 文件（主循环核心之外）判定

**必须复刻**（核心增强，手机更重要）：
- `context_compressor` / `conversation_compression` — 上下文摘要压缩（手机内存更关键）
- `tool_dispatch_helpers` / `tool_guardrails` — 工具并行门控、护栏（主循环一部分）
- `file_safety` — 沙盒内文件白名单
- `subagent_lifecycle` — 子代理生命周期契约（App 多任务核心）
- `iteration_budget` — 迭代预算防死循环
- `error_classifier` — 错误分类→重试/轮换/降级/压缩/中止（弱网更重要）
- `retry_utils` — jittered backoff

**留接口**：
- Provider 适配层（anthropic/bedrock/gemini/vertex/azure/codex）：Dart 只实现 anthropic + openai-compatible 两条；schema 翻译思路参考
- `memory_provider` 抽象、`prompt_caching`（缓存省钱）、`model_metadata`（token 估算）、`credential_pool`（多 key 故障切换）、SKILL.md 加载注入、`tool_result_classification`

**跳过**：
- billing/计费/Nous 门户绑定、桌面 UI（apps/pet/learning_graph 渲染）、learning_graph/insights/trajectory、display.py（终端渲染，Flutter 自带 UI）、lsp/、monitoring/、moa_loop/moa_trace、reactions/battery/i18n/markdown_tables、verification 系列、browser/image_gen/tts/web_search/video_gen 的 provider+registry（保留模式）

### 4.3 值得保留的核心抽象汇总（Dart 复刻骨架）

1. **会话管理**：gateway/session.py 的 SessionStore + ResetPolicy + 动态上下文注入、"一次会话一个 agent"
2. **Provider ABC + Registry 发现器**：单 provider 激活（贯穿 plugins 与 agent/*_registry）
3. **Provider 统一接口 + OpenAI schema 翻译**（anthropic_adapter 思路）
4. **context_compressor / conversation_compression**：上下文压缩
5. **error_classifier**：错误分类→恢复动作
6. **iteration_budget**：防死循环
7. **subagent_lifecycle**：子代理生命周期
8. **credential_pool**：多 key 故障切换
9. **file_safety**：沙盒文件白名单
10. **tool_dispatch_helpers / tool_guardrails**：工具调度护栏
11. **COMMAND_REGISTRY**：slash 命令单一定义表
12. **SKILL.md 解析注入**
13. **prompt_caching**
14. **model_metadata**：token 估算

---

## 五、手机可用工具子集（复刻清单）

> 数据来源：子代理 B 汇总

**✅ 手机上真正能用的子集**（纯文件系统 / 纯 HTTP / 纯内存状态，无子进程、无桌面、无音频设备）：

- 文件：read_file / write_file / patch / search_files（⚠️ rg）
- 记忆·会话：memory / todo / kanban(12) / project / session_search / clarify（⚠️）
- 任务：delegate_task / cronjob
- 技能：skills_list / skills_view / skill_manage
- 网络：web_search / web_extract（带 key）、vision_analyze
- MCP 客户端：HTTP/SSE 服务器（stdio ❌）

**复刻建议**：
- **必复刻（P0/P2）**：registry 骨架（name/toolset/JSON-Schema/check_fn/handler(args dict)→JSON）、file 工具族、memory/todo/kanban/project/session_search、delegate_task（进程内子 agent，Dart 用 isolate/协程递归 agent 循环）、web 抓取搜索、vision_analyze、MCP 客户端（HTTP/SSE）
- **留接口**：terminal（本地 subprocess 或 SSH 远端后端，可对接 Termux SSH）、浏览器（CDP override 连远端）、图像/视频生成、TTS、三方平台 token 适配器
- **直接跳过**：computer_use、桌面 GUI 系列（focus_pane/read_terminal/open_preview/react_to_message）、voice_mode/wake_word/转写、code_execution 沙箱、Camofox

---

## 六、复刻顺序建议

> 待映射表定稿后填充

<!-- 待填充 -->

---

## 附：Hermes master 模块全景（目录清单，2026-08-02 抓取）

### 根目录核心文件
```
run_agent.py (336KB)  model_tools.py (65KB)  hermes_state.py (383KB)
hermes_state_common.py  hermes_state_schema.py  hermes_state_search.py  hermes_state_portability.py
hermes_constants.py  hermes_time.py  hermes_logging.py  hermes_bootstrap.py
batch_runner.py  cli.py  mcp_serve.py  mini_swe_runner.py
```

### agent/（126 个文件）
主循环核心：`conversation_loop.py (392KB)` `agent_init.py (135KB)` `prompt_builder.py` `system_prompt.py` `context_compressor.py` `context_engine.py` `memory_manager.py (48KB)` `tool_executor.py` `tool_dispatch_helpers.py` `message_content.py` `turn_context.py` `turn_finalizer.py` `runtime_cwd.py` `display.py (55KB)` `moa_loop.py` `iteration_budget.py` `error_classifier.py` `subagent_lifecycle.py`
其余 ~110 文件：adapter（anthropic/bedrock/codex/gemini/vertex/azure）、billing、context_breakdown/references、credential、delegation、image/tts/video/web_search registry、learning_graph、reasoning、redact、relay、skill_*、ssl、stream、trajectory、usage 等

### tools/（约 100 个文件）
`registry.py (41KB)` `schema_sanitizer.py` 工具文件含 file_tools/file_operations/web_tools/url_safety/ansi_strip/terminal_tool/browser_*/tts_*/vision_tools/feishu_*/discord_tool/delegate_tool/todo_tool/skills_*/cronjob_tools/computer_use* 等

### gateway/（40+ 文件）
`platform_registry.py` `platforms/` `session.py` `run.py` `delivery.py` `hooks.py` `mirror.py` `pairing.py` 等

### hermes_cli/（60+ 文件）
`cli.py` `commands.py` `config.py` `auth.py` `banner.py` `console_engine.py` `colors.py` 等

### plugins/（20+ 目录）
browser / context_engine / cron_providers / dashboard_auth / google_meet / image_gen / kanban / memory / model-providers / observability / platforms / security-guidance / spotify / teams_pipeline / video_gen / web 等

### skills/（14 目录）
apple / autonomous-ai-agents / creative / email / github / media / mlops / note-taking / productivity / research / smart-home / social-media / software-development / index-cache

### cron/ / acp_adapter/ / apps/
`cron/scheduler.py` `cron/jobs.py`；`acp_adapter/`（IDE 集成）；`apps/`（bootstrap-installer / desktop / shared）

---

> 映射表由 3 个并行研究子代理产出原始清单后汇总。
> **本文件在子代理数据到达后填充完整。**
