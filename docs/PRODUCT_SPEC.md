# Codex Synced 功能设计

## 1. 产品定位

Codex Synced 是一个 Windows / macOS 桌面应用，用于修复 Codex Desktop
本地侧边栏历史不可见、标题显示为“新对话”、项目缺失和排序异常问题。

本项目中的“同步”特指：

> 修复 Codex Desktop 侧边栏摘要所依赖的本地状态：SQLite 线程摘要、
> `session_index.jsonl`、rollout 文件 mtime、短标题和全局 UI 状态。

它不是云同步、Git 同步或多设备同步工具。

## 2. 问题背景

早期版本把问题简化成 Provider 分桶：Codex 会按照 `model_provider`
区分一部分本地历史。但 2026-06 的实际故障证明，Desktop 侧边栏还依赖
app-server `thread/list` 摘要、SQLite `threads.title`、`updated_at_ms`、
rollout 文件 mtime、`session_index.jsonl` 和 `.codex-global-state.json`。

| 使用模式 | `config.toml` 根级 `model_provider` | 新会话 Provider |
| --- | --- | --- |
| 官方 OAuth 认证 | 通常不存在 | `openai` |
| 第三方 API 中转站 | `custom` 或其他值 | 对应配置值 |

当 `threads.title` 为空或等于 `first_user_message` 时，`thread/list` 可能返回
`name:null`，Desktop 退化显示“新对话”。如果修复工具批量触碰 rollout 文件，
默认扫描路径还会按错误 mtime 排序，出现大量会话同一天、顺序混乱的问题。

## 3. 核心目标

1. 自动识别当前 Codex Provider 和状态库。
2. 扫描本地历史会话，统计待修复项。
3. 在用户确认后创建备份。
4. 仅在 rollout metadata 证明 SQLite provider 错误时修复 Provider。
5. 修复短标题、更新时间、rollout mtime、会话索引和全局 UI 状态。
6. 修复完成后允许用户直接打开 Codex。

## 4. Provider 判定规则

应用只读取 `config.toml` 根级字段，不读取任何 section 内的同名字段。

```text
如果根级存在 model_provider：
    使用该值，例如 custom

如果根级不存在 model_provider：
    默认使用 openai
```

必须忽略此类嵌套字段：

```toml
[mcp_servers.example]
model_provider = "openai_http"
```

否则官方 OAuth 模式可能被错误识别成 `openai_http`。

应用可以展示实际认证类型：

- `OpenAI OAuth`
- `OpenAI API Key`
- `第三方 API`

Provider 修复不得由当前根级 Provider 批量决定。正确规则是：

```text
如果 rollout session_meta.payload.model_provider 存在，
且与 threads.model_provider 不一致：
    将 threads.model_provider 修正为 rollout 中的 provider

不得把所有历史批量改成当前 config.toml provider。
不得为 Provider 修复改写 rollout 第一行。
```

## 5. 扫描范围

应用自动识别实际的 `state_*.sqlite`，不得写死 `state_5.sqlite`。

扫描范围：

```text
~/.codex/config.toml
~/.codex/state_*.sqlite
~/.codex/session_index.jsonl
~/.codex/sessions/**/rollout-*.jsonl
~/.codex/archived_sessions/**/rollout-*.jsonl
```

如用户设置了 `CODEX_HOME`、`CODEX_SQLITE_HOME` 或 `sqlite_home`，应用应优先
使用对应目录。

## 6. 修复范围

### 6.1 Provider 错配修复

用户确认后，应用执行：

1. 更新状态库中的：

```text
threads.model_provider
```

2. 修复目标必须来自对应 rollout 第一行 metadata。
3. 保持 rollout 文件内容和会话正文不变。

### 6.2 侧边栏摘要修复

应用应检查并按需修复：

```text
threads.title
threads.updated_at
threads.updated_at_ms
rollout JSONL 文件 mtime
session_index.jsonl
.codex-global-state.json selected-remote-host-id
.codex-global-state.json remote-control auto-connect
.codex-global-state.json project-order
```

`threads.title` 应写入短标题，且必须与 `first_user_message` 不同，避免
`thread/list` 返回 `name:null`。`session_index.jsonl` 应按 resume-compatible
活跃会话清单重建，而不是只追加缺失项；已有重复、过期、时间漂移条目都应被清理。

### 6.3 保守兼容

不得为了“可见性”批量伪造：

```text
threads.has_user_event
threads.cwd
threads.thread_source
```

这些字段只有在未来有官方 schema 证据时才能加入修复。

### 6.4 明确禁止修改

应用不得修改：

- OAuth Token
- API Key
- 第三方中转站 URL
- CC Switch Provider 配置
- 会话正文
- Codex.app 本体

## 7. 备份设计

每次存在实际待修复项时，必须先创建备份。若扫描结果为零，不创建备份。

用户可以选择两种备份模式。

### 7.1 轻量备份

默认模式，默认最多保留 `5` 份。

保存：

- 完整 `state_*.sqlite`
- 存在时保存对应 `-wal` 和 `-shm`
- 对存在的 `state_*`、`thread_history_*`、`logs_*` 数据库生成 SQLite Backup API 一致快照
- `config.toml`
- `session_index.jsonl`
- 必要的全局状态小文件
- rollout 文件原始 mtime
- 每个待改 rollout 文件的原始第一行 metadata（仅兼容旧备份）
- 备份描述文件

不重复保存会话正文。当前修复不会改写 rollout 内容；轻量备份只保存状态库、索引、
全局状态和 mtime 回滚数据。

### 7.2 全量备份

默认最多保留 `3` 份。

除轻量备份内容外，额外保存：

- 完整 `sessions`
- 完整 `archived_sessions`
- 与修复有关的本地状态文件

适用于首次使用、重大版本升级后或用户主动要求更强灾备的场景。

分页 rollout 的 Provider 差异默认仍作为风险展示，不进入普通一键修复。v1.6.0 在证明完整分支链和偏移重算后，允许用户在独立确认流程中同步修改分页首行、`history_base`、历史库 turn 偏移和 projection 游标；未通过校验的项目仍只读并要求人工调查，不得伪造“正文已修复”。

### 7.3 轮换规则

- 两种模式分别维护最大备份数量。
- 用户可以修改两个上限。
- 新备份成功后，自动删除该模式中最旧的超额备份。
- 删除前必须确认新备份完整可读。

## 8. 安全约束

1. Codex 正在运行时不得直接写入状态库。
2. 检测到 Codex 正在运行时，提示用户：
   - `退出 Codex 并继续修复`
   - `取消`
3. 修复前展示 dry-run 摘要。
4. 修复失败时停止打开 Codex，并展示错误和日志位置。
5. 状态库和 rollout 修改必须支持回滚。
6. 日志不得记录 OAuth Token、API Key 或完整敏感 URL。

## 9. 页面设计

界面使用中文为默认语言，提供 `中文 / English` 切换。视觉风格遵循 macOS
原生应用审美，布局简洁，避免数据库管理器式界面。

### 9.1 首页：修复状态

展示：

- 当前认证方式
- 当前 Provider
- Codex 本地目录
- 当前状态库
- 最近一次修复时间
- 当前扫描状态
- 最近备份记录
- Provider 错配、短标题、时间、索引和 UI 状态指标

主操作：

- `扫描待修复项`
- `立即修复`
- `查看待修复项`
- `打开备份目录`
- `打开 Codex`

当没有待修复项时，主状态显示：

```text
侧边栏状态正常
```

### 9.2 待修复项

展示修复前 dry-run 摘要：

| 项目 | 数量 |
| --- | ---: |
| 按 rollout 修正 Provider 的 SQLite 记录 | 动态统计 |
| 待写入短标题 | 动态统计 |
| 待修复更新时间 | 动态统计 |
| 待重建索引条目 | 动态统计 |
| 全局 UI 状态变更 | 动态统计 |
| 当前目标 Provider | 当前配置值 |

底部操作：

- `备份并修复`
- `取消`

### 9.3 备份

展示：

- 备份时间
- 备份模式
- 目标 Provider
- 大小
- 修复摘要

操作：

- `恢复此备份`
- `打开备份目录`

恢复操作必须二次确认。

### 9.4 设置

保留以下设置：

- 界面语言
- Codex 本地目录
- SQLite 目录
- 默认备份模式：`轻量备份 / 全量备份`
- 轻量备份最大数量，默认 `5`
- 全量备份最大数量，默认 `3`
- 修复完成后自动打开 Codex

## 10. 完整用户流程

```text
用户发现 Codex Desktop 侧边栏缺项目、显示“新对话”或时间排序异常
        ↓
打开 Codex Synced
        ↓
应用读取本地状态并执行 dry-run
        ↓
展示待修复摘要
        ↓
用户点击“备份并修复”
        ↓
创建轻简或全量备份
        ↓
修复 SQLite 摘要、rollout mtime、索引和 UI 状态
        ↓
验证修复结果
        ↓
打开 Codex
```

## 11. 第一版交付范围

第一版必须具备：

- Provider 自动识别
- `state_*.sqlite` 自动识别
- dry-run 扫描
- Provider 错配修复（以 rollout 为准）
- 侧边栏标题、时间、索引和 UI 状态修复
- 轻量备份
- 全量备份
- 两种备份数量上限和自动轮换
- 备份恢复
- 中英文界面
- DMG 安装包

暂不包含：

- 云端同步
- GitHub 数据同步
- 多设备同步
- 修改 CC Switch 配置
- 修改 Codex.app 本体
- 改写 rollout 会话正文

## 12. 后续评估项

Codex Desktop 某些版本只预加载最近一页会话。即使历史数据已修复，较旧项目仍可能
因为前端分页策略暂时不出现在侧边栏。

第一版不自动修改会话时间排序。后续可单独评估“历史可见性增强”功能，并明确展示
它会改变最近会话排序。
