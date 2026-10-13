# Provider 切换历史可见性修复方案

## 背景

切换 Codex 根级 `model_provider`（例如官方 Provider 与第三方中转站之间切换）后，旧会话可能因为本地 Provider 元数据不一致而从侧边栏消失。当前版本已经能够把可恢复会话的 `threads.model_provider` 对齐到根级 Provider；但分页 rollout 文件包含 `history_base` 字节边界，不能像旧格式一样直接重写首行，否则会使分支边界和历史投影偏移失效。

本方案只处理 Provider 可见性，不改变会话入口选择、历史分支、正文、标题、项目归属或 API 配置。

## 目标

1. 切换 Provider 后，准确识别 SQLite、rollout metadata 与当前根级 Provider 的差异。
2. 对安全范围内的旧格式会话继续自动修复。
3. 对分页会话不静默地产生“SQLite 已修复、rollout 仍不一致”的半修复状态。
4. 所有真实写入前都能在 WAL 安全备份和隔离副本中验证，并在写入后使用只读读取接口验收。
5. 保留原对话 ID、标题、cwd、项目归属、正文、`history_base` 和物理分支文件。

## 分层策略

### 第一阶段：Provider 诊断和安全预览（先实现）

- 建立每条会话的 Provider 状态：根级配置、SQLite `model_provider`、rollout 首行 Provider、`history_mode`。
- 将分页 rollout 的 Provider 不一致显示为独立的“分页 Provider 元数据需人工确认”项目，而不是把它伪装成普通 Provider 修复。
- 继续允许只修改 SQLite Provider 的保守模式，但界面必须明确提示：这不会改写分页 rollout 首行。
- 旧格式 rollout 继续使用现有首行修复逻辑。
- Provider 修复预览显示实际文件和数据库字段，不显示笼统的“若干条”。

### 第二阶段：分页 Provider 安全修复（单独功能）

只有用户明确确认且所有前置条件通过时才允许执行：

- 先建立全局物理分支索引，按 `history_base.thread_id` 找到跨逻辑对话的父文件。
- 计算每个文件每个 ordinal 的真实字节边界。
- 预测首行 Provider 改写造成的字节增量，并重新计算受影响父文件及所有后代的：
  - `history_base.end_byte_offset`
  - `thread_turns.rollout_byte_offset`
  - `thread_turns.rollout_end_byte_offset`
  - `thread_history_projection_state.next_rollout_byte_offset`
- 只接受唯一完整分支链；存在多末端、重复物理 ID、缺父文件、未知文件或边界无法重建时拒绝自动修复。
- SQLite 偏移和状态入口使用旧值条件更新；JSONL 只允许精确首行字段修改，不拼接、不重建正文。
- 变更前同时保存 `state_*.sqlite`、`thread_history_*.sqlite`、`logs_*.sqlite` 的 SQLite Backup API 快照，以及所有受影响 rollout 文件。

### 第三阶段：读取验收和回归

- 在隔离 Codex Home 中调用 `thread/read` 与 `thread/turns/list`。
- 比较 turn ID、顺序、用户/助手正文哈希、重复项和遗漏。
- 真实写入后再次执行只读分页验收；桌面缓存未刷新时明确提示正常重启，而不是报告为已完成。
- 增加跨逻辑父分支、50 字节中间偏移、Provider 首行长度变化、WAL、编辑替换、未知文件和多末端分支测试。

## 不做的事

- 不直接串接或重建 JSONL 正文。
- 不删除旧物理分支，不清空历史库，不修改 OAuth、API Key、URL 或根级 Provider 配置。
- 不根据文件 mtime 猜测活跃入口。
- 不把未知文件警告扩大为阻断所有无关会话；警告应限定到受影响的逻辑会话。

## 验收标准

- 当前 Provider 已一致时扫描结果为零，不产生无意义改写。
- Provider 切换后，旧格式会话可以完整修复；分页会话要么完整修复所有关联偏移，要么清晰地进入人工确认状态。
- 修复前后正文逐条一致，turn 无重复、无遗漏。
- 标题、ID、cwd、项目归属和归档状态不变。
- WAL 快照可独立通过 SQLite 完整性检查，失败时事务和文件改写均可回滚。

## 发布拆分

- v1.5.0：第一阶段诊断、分页 Provider 风险提示、全局物理分支索引、隔离读取验收和回归测试。
- v1.6.0：第二阶段分页 Provider 安全修复，在真实样本和副本验收通过后再开放默认入口。

## 当前落地状态

v1.5.0 已完成第一阶段的本地安全边界：分页 Provider 只进入人工确认；普通格式继续按现有安全规则对齐；扫描会按会话目录局部阻断未知文件并忽略明确的临时/修复残留；轻量备份会同时保存活动 SQLite 文件三件套和 SQLite Backup API 一致快照。客户端隔离 `thread/read` / `thread/turns/list` 仍是发布后的人工验收项，分页首行改写及偏移重算留在 v1.6.0，不作为本版本的隐藏行为。
