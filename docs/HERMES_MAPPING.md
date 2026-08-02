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

> 数据来源：子代理 B（tools/ 全部）

<!-- 待填充 -->

---

## 四、外围模块（不复刻 / 留接口）

> 数据来源：子代理 C（gateway / hermes_cli / plugins / skills / cron / 其余）

<!-- 待填充 -->

---

## 五、手机可用工具子集（复刻清单）

> 数据来源：子代理 B 汇总

<!-- 待填充 -->

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
