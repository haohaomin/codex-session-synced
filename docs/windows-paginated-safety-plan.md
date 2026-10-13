# Windows 分页 Provider 修复方案

## 目标

在 Windows 版继续支持 Provider 切换后的普通历史可见性修复，并提供与 macOS 一致的分页 Provider 第二阶段修复。分页文件的 `history_base` 字节边界依赖首行的精确 UTF-8 长度，所有改写必须先完成 lineage、边界和历史库偏移校验。

## 范围

实现分为两个互斥入口，不重建正文、不拼接 JSONL：

1. 扫描 rollout 时识别 `history_mode = paginated`、`history_base` 或 `ordinal`。
2. 将分页线程从普通 SQLite Provider 对齐和 rollout 首行写入计划中排除。
3. 对唯一可解释的 lineage 生成独立修复计划，重算 `history_base.end_byte_offset`、`thread_turns` 和 projection。
4. 副本先行：使用 SQLite Backup API 创建 state/history 快照和 rollout 副本，试写通过后才写真实文件；旧值 CAS、正文哈希和失败恢复必须同时通过。
5. 生成统一风险卡片，区分“可安全重算”和“需人工确认”，展示当前 Provider、目标 Provider、偏移数量和诊断原因。
6. 保留标题、时间、索引等与首行字节边界无关的普通修复；执行前仍先备份。
7. 增加 Windows self-test：覆盖有效分页修复、正文哈希、偏移收敛和异常诊断。

## 不在本阶段做的事

- 不在 Windows 端猜测活跃物理分支。
- 不在普通“备份并修复”按钮中直接改写分页 `session_meta` 首行。
- 不猜测活跃物理分支；多个末端、缺父文件、重复物理 ID、非法序号或边界不一致必须只读诊断。
- 不杀 Codex 进程、不清空数据库、不批量迁移历史。

## 验收标准

- 普通旧格式 Provider 修复行为保持不变。
- 分页 Provider 不一致不会进入普通写入；有效计划进入独立确认流程。
- `--self-test` 验证分页 rollout 的正文哈希、Provider、`history_base`、turn 和 projection 收敛。
- Windows 项目在 Windows 构建机可编译并运行 self-test；README 记录构建机外的验证限制。

## 后续阶段

剩余验收包括 Windows 构建机完整编译、真实副本的 `thread/read` 对照，以及退出并重启 Codex 后的正文顺序、遗漏、重复和项目归属检查。通过后再把 Windows 版本加入发布产物。
