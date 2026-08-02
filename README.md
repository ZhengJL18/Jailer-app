# Jailer

在 Flutter 隔离墙（Android App 沙盒）内实现 agent 级能力的纯 Dart 框架。

**复刻策略**：以开源 [Hermes Agent](https://github.com/NousResearch/hermes-agent)（master）为唯一行为规范，用 Dart 逐文件重写其核心闭环。不自创工具系统。

**当前阶段**：复刻映射表（见 `docs/HERMES_MAPPING.md`）——先把"必须复刻 / 手机不可用跳过 / 适配"钉死，再按 P0→P1→P2 推进逐文件 Dart 复刻。
