# Windows 分页 Provider 安全边界方案

## 目标

在 Windows 版继续支持 Provider 切换后的普通历史可见性修复，同时阻止普通修复流程改写分页 rollout 的首行。分页文件的 `history_base` 字节边界依赖首行的精确 UTF-8 长度；在尚未移植完整偏移重算器之前，Windows 不能把分页文件当作旧格式文件直接写回。

## 范围

本阶段只处理安全边界，不重建正文、不拼接 JSONL、不修改真实 Codex 数据库之外的内容：

1. 扫描 rollout 时识别 `history_mode = paginated`、`history_base` 或 `ordinal`。
2. 将分页线程从普通 SQLite Provider 对齐和 rollout 首行写入计划中排除。
3. 生成独立的分页 Provider 风险项，展示当前 Provider、目标 Provider 和文件路径，明确需要人工确认。
4. 保留标题、时间、索引等与首行字节边界无关的安全修复；执行前仍先备份。
5. 增加 Windows self-test：分页文件即使 Provider 不一致，也不会出现在普通写入计划中，执行修复后首行和正文逐字节不变。

## 不在本阶段做的事

- 不在 Windows 端猜测活跃物理分支。
- 不直接改写分页 `session_meta` 首行。
- 不移植 `history_base.end_byte_offset`、`thread_turns` 和 projection 的完整重算，直到 Windows SQLite schema 和副本验收流程具备同等覆盖。
- 不杀 Codex 进程、不清空数据库、不批量迁移历史。

## 验收标准

- 普通旧格式 Provider 修复行为保持不变。
- 分页 Provider 不一致只产生风险提示，不产生 SQLite Provider 或 rollout 首行写入项。
- `--self-test` 验证分页 rollout 的 SHA-256 和正文内容保持一致。
- Windows 项目可编译，README 记录该平台边界：分页风险可诊断，但完整分页偏移修复仍需 macOS 1.6.0 或人工确认。

## 后续阶段

在独立方案和副本验证完成后，再考虑把 macOS 的分页 Provider 修复器移植到 Windows；移植必须覆盖 WAL 一致备份、唯一 lineage 校验、字节边界重算、失败恢复和重启后的真实 `thread/read` 验收。
