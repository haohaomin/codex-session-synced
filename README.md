# Codex Synced

[English](README_EN.md) | 中文

Codex Synced 是一个 Windows / macOS 本地修复工具，用来解决 Codex Desktop 侧边栏会话历史不可见、标题显示为“新对话”、时间排序异常等本地状态问题。

它会预览需要修复的本地记录，并在备份后修复 SQLite 摘要、`session_index.jsonl`、rollout 文件 mtime 和 `.codex-global-state.json` 中影响侧边栏显示的字段。默认会把可恢复的普通会话（包括归档会话）及其**可安全改写的** rollout metadata 对齐到当前根级 `model_provider`，解决切换官方或第三方 Provider 后历史被过滤的问题；分页 rollout 的 Provider 不一致会单独标记为需确认，不会在未重算 `history_base` 字节边界前直接改写。也可以在设置中关闭跨 Provider 对齐，改为仅按 rollout 修正 SQLite。

它不是云同步工具，也不会上传你的会话。所有扫描、备份、修复都发生在本机。

## 1.8.0：完成双平台统一设计

1.8.0 补齐 1.7.0 发布后的跨平台一致性：Windows 持久化语言选择，检测 Desktop/CLI/app-server 写入进程；对话入口扫描要求唯一状态库、按目录阻断未知文件，并在 SQLite 副本验证入口写入后才提交；macOS 也增加同样的副本入口校验。

[1.8.0 发布说明](docs/release/v1.8.0.md) · [下载 Codex Synced 1.8.0](https://github.com/haohaomin/codex-session-synced/releases/tag/v1.8.0)

## 1.7.0：Windows / macOS 功能统一

本版本完成双平台统一修复入口和风险设计：

- Windows 与 macOS 都支持「对话修复」：只读 lineage 诊断、最小 `rollout_path` 修复和条件撤销。
- 分页 Provider 修复在两端都独立于普通 Provider 对齐，先副本试写，再同步首行、`history_base`、turn 和 projection 偏移。
- 两端统一“诊断 → 预览 → 备份 → 写入 → 复核”流程、风险分层、退出 Codex 检查和重启后人工验收边界。
- Windows 现在持久化语言选择，并检测 Desktop、CLI 和 app-server 写入进程；未知 rollout 文件只阻断同目录对话。

[统一设计规范](docs/unified-design.md) · [1.7.0 发布与验收方案](docs/release/v1.7.0-publish-plan.md)

## 1.5.0：Provider 切换诊断与安全备份

本版本把 Provider 切换后的可见性修复、分页风险提示和备份边界统一到同一套“诊断 → 预览 → 备份 → 验收”流程。分页 rollout 仍不会被静默改写；需要重算 `history_base` 的情况会明确停在人工确认。

[1.5.0 发布说明](docs/release/v1.5.0.md) · [下载 1.5.0](https://github.com/renhao12356578/codex-session-synced/releases/tag/v1.5.0)

[1.6.0 发布说明](docs/release/v1.6.0.md) · [下载 macOS 1.6.0](https://github.com/haohaomin/codex-session-synced/releases/tag/v1.6.0)

[1.7.0 发布说明](docs/release/v1.7.0.md) · [下载 Codex Synced 1.7.0](https://github.com/haohaomin/codex-session-synced/releases/tag/v1.7.0)

- **Provider 风险分层**：普通格式会话继续支持安全对齐；分页 Provider 差异独立展示，不把 SQLite 元数据修复冒充为正文修复。
- **WAL 一致备份**：轻量备份保留活动数据库的主文件、WAL/SHM，并额外写入 `SQLite Backup API` 一致快照；同时覆盖存在的 `state_*`、`thread_history_*` 和 `logs_*` 数据库。
- **局部未知文件阻断**：临时文件、修复残留和备份副本会被忽略；无法识别的 rollout 只阻断同目录会话，不再让无关目录全部停摆。
- **统一风险界面**：待修复项和对话修复页使用统一的状态卡片、风险卡片和验收边界文案。
- **Windows 分页统一链路**：Windows 已移植分页 lineage、`history_base`、`thread_turns` 与 projection 的独立修复计划，并将普通修复与分页确认入口分开；通过 Windows 构建机编译、自测和真实副本验收后才纳入发布包，详见 [Windows 分页修复方案](docs/windows-paginated-safety-plan.md)。

## 1.6.0：分页 Provider 安全修复

分页会话的 Provider 切换现在具备独立的第二阶段修复路径，不会混入普通“备份并修复”。[实施方案](docs/paginated-provider-repair-plan.md)记录了以下新能力：

- **自动建立全局物理分支索引**：校验唯一物理 ID、父分支、末端和 ordinal 连续性；多历史库、跨文件重复 ID、缺父文件或无法解释的边界会局部阻断并显示诊断。
- **按字节增量重算偏移**：Provider 首行长度变化后，同步更新后代 `history_base.end_byte_offset`、`thread_turns` 起止偏移和 projection 游标，不拼接、不重建正文。
- **副本试写与显式确认**：先用 SQLite Backup API 和唯一临时 rollout 副本试写，只有通过完整性检查后才允许用户单独确认分页修复。
- **失败保护**：真实写入使用旧值条件更新、rollout 首行 compare-and-swap、正文哈希和本次备份恢复；运行中的 Codex 不会被终止。
- **诊断可见**：分页无法安全解释时，界面直接显示原因；通过校验的项目进入“可安全重算分页偏移”区域。

当前版本仍要求修复后重新打开并重启 Codex，逐条核对正文、遗漏、重复和项目归属；自动化测试已覆盖 50 字节中间偏移、多数据库阻断和备份恢复。

## 1.4.0：对话诊断与入口修复（历史版本）

新增独立的「对话修复」页面，用于**原始 JSONL 仍在，但主对话入口停留在旧分支，导致后续消息不显示**的情况。本功能不混入原有侧边栏一键修复；macOS 与 Windows 均提供只读 lineage 诊断、最小入口修复和安全撤销。Windows 的分页 Provider 偏移修复也使用独立确认入口，不混入普通 Provider 修复。

[1.4.0 发布说明](docs/release/v1.4.0.md)

- **只读诊断与预览**：读取 `sessions`、`archived_sessions` 与状态库，区分主对话 ID 和文件名中的物理分支 ID，沿原始 `history_base` 检查完整的唯一后继链。不按文件修改时间猜测活跃分支。
- **保守阻断**：遇到多个末端、循环、重复物理 ID、缺失父文件、非法 JSON、序号不连续、字节偏移不一致、符号链接或未知格式，拒绝自动修复。有效继承范围的消息记录统计排除被替换的父分支尾部，但不是客户端轮数。
- **逐条确认、最小写入**：必须先退出 Codex Desktop 及 Codex CLI/app-server。每次只修改选中对话的 `threads.rollout_path`，保留所有其他列，包括原 ID、标题、项目、`cwd`、分组、归档状态。不改写历史数据库，不合并、重建或拼接正文。
- **WAL 安全备份与副本试写**：使用 SQLite Backup API 保存状态库（包含已提交的 WAL 内容），另存分支链原文件。先在独立数据库副本试写，再对真实库进行事务内检查、写入与完整性校验；预览过期则拒绝操作。
- **安全撤销**：只反向更新本次入口字段，不覆盖整库。若目标记录、任一源文件或分支链发生变化，则拒绝撤销，保护新消息。备份目录为所选 Codex Home 下的 `history-entrypoint-backups/`，不参与旧备份的自动轮换。记录在提交前持久化，包含未提交的操作意图，不能仅凭记录存在判断修复成功。
- **保护分页文件**：macOS 原有 Provider 修复不再改写带 `history_mode: paginated`、`history_base` 或 `ordinal` 的 JSONL 首行，避免使后继分支保存的字节偏移失效。旧格式的 Provider 修复不变。
- **分页 Provider 风险提示**：扫描会显示 SQLite 与分页 rollout Provider 的差异；这类项目需要单独确认，不会被误报为已完成的正文或历史修复。

### 使用与验收边界

1. 安装并打开 macOS 1.5.0，进入「对话修复」，点击「只读扫描」。可在设置中指定 Codex Home / SQLite Home；选定的 SQLite 目录必须仅包含一个 `state_*.sqlite`。
2. 检查建议入口与诊断依据，正常退出 Codex 及相关 CLI 后，逐条确认「备份并修复入口」。异常项需人工调查，不提供强制修复开关。
3. 修复后重新打开原对话，检查有效消息的内容、顺序、遗漏和重复；再正常退出并重启 Codex，检查正确分支是否仍然可读，以及项目归属是否不变。
4. 必要时在同一页面的修复记录中撤销。若提示数据已变化，不要直接用旧数据库覆盖当前数据库。

**当前自动验证范围**：原始分支文件逐字节 SHA-256 一致、完整序号/继承字节边界、除入口外全部 SQLite 字段不变，以及 SQLite 完整性。副本试写只验证数据库修改，**没有在隔离客户端内执行 `thread/read` / 分页 API 的逐条正文对照，也没有自动验证桌面重新打开与重启持久性**。因此成功提示是「入口已修复」，不是「对话全部验收通过」。字节偏移不一致（包括已知相差 50 字节的情况）仅报告，不自动修正。

备份包含私人对话正文和数据库元数据，请按原始数据同等保护。轻量备份现在会对存在的状态、历史和日志数据库生成 WAL 一致快照；这仍不是跨多个数据库的原子事务。扫描和验证耗时取决于本地分支文件大小。

新增回归测试使用独立临时样本，覆盖编辑替换、元数据与原文件保留、WAL 备份、过期预览、缺失/歧义分支、偏移异常、事务回滚及拒绝覆盖后续变化。

[实现与验证记录](docs/history-repair-validation.md)（包含本机构建命令和未完成的验收项目）。

## 1.3.0 更新内容

相较于 1.2.7，本版本新增以下修复和兼容性改进：

- **修正状态库选择**：同时检查 `.codex` 根目录与 `sqlite` 子目录，结合数据库及 WAL/SHM 修改时间选择状态库，避免旧的子目录数据库遮蔽根目录中的活跃数据库。
- **补齐归档会话的 Provider 对齐**：将已归档的普通会话也纳入对齐范围，同步更新 SQLite 和 rollout 首行 metadata，修复切换 Provider 后归档历史不可见的问题。
- **重建索引时保留更多记录**：`session_index.jsonl` 重建覆盖具有本地 rollout 文件的归档会话和内部线程，避免遗漏这些记录，并保持 ID 唯一。
- **兼容新版标题字段**：优先读取非空的 `threads.name`，修复标题时同步更新 `name` 与 `title`。
- **恢复损坏标题**：识别生成标题中的工具调用残片，从会话预览或首条用户消息恢复标题。
- **修正创建时间异常**：检测 `created_at > updated_at` 的记录，利用 rollout 时间及可用的 recency 时间修正创建时间，支持秒和毫秒字段。
- **降低首行改写的内存占用**：流式替换 rollout 首行，保留后续消息正文，避免改写时将整个大型会话载入内存。
- **提高 macOS 打包稳定性**：将 DMG 的 Finder 布局超时延长至 300 秒。

本次还补充了状态库选择、归档会话、损坏标题、创建时间及索引保留场景的回归测试。Windows 自测与双平台发布构建已通过。

[完整更新说明](docs/release/v1.3.0.md) · [下载 1.3.0](https://github.com/renhao12356578/codex-session-synced/releases/tag/v1.3.0)

![Codex Synced 首页](docs/screenshots/home-zh.png)

## Windows 下载与使用

1. 前往 [GitHub Releases](https://github.com/haohaomin/codex-session-synced/releases/latest) 下载 `Codex-Synced-Windows-x64-1.8.0.msi`。
2. 退出 Codex。
3. 双击 MSI 完成安装，然后从开始菜单打开 `Codex Synced`。
4. 查看待修复项，选择备份模式，点击“备份并修复”。
5. 分页 Provider 或后续消息不可见时，进入“对话修复”，先只读扫描，再逐条确认分页修复或入口修复。
6. 重新打开并重启 Codex，检查历史会话正文、顺序、遗漏、重复和项目归属。

Windows 版是完整桌面应用安装包，默认读取 `%USERPROFILE%\.codex`，并会自动识别当前活跃的状态库目录；也可以在设置中修改目录。Release 中也提供 `Codex-Synced-Windows-x64-1.8.0.zip`，用于不想安装时手动运行应用目录。

## macOS 下载与安装

1. 前往 [GitHub Releases](https://github.com/haohaomin/codex-session-synced/releases/latest) 下载 `Codex-Synced-macOS-1.8.0.dmg`。
2. 双击打开 DMG。
3. 将 `Codex Synced.app` 拖入 `Applications`。
4. 第一次打开时，如果 macOS 提示来自未验证开发者，请在 Finder 中右键点击应用，选择“打开”，再确认打开。
5. 使用前请先退出 Codex，避免本地状态文件正在被写入。

### macOS 提示“无法验证”或“已损坏”怎么办？

当前版本暂未经过 Apple 公证。macOS Gatekeeper 可能会把未公证的下载 app 标记为“无法打开”“无法验证开发者”，甚至显示“已损坏并无法打开”。这通常是下载隔离属性触发的安全拦截，不代表 app 文件真的损坏。

建议按下面顺序处理：

1. 确认 DMG 来自本项目的 [GitHub Releases](https://github.com/renhao12356578/codex-session-synced/releases)。
2. 可选：校验下载文件的 SHA256，应与 Release 页面一致：

```bash
   shasum -a 256 ~/Downloads/Codex-Synced-macOS-1.8.0.dmg
```

3. 先尝试 Apple 推荐的方式：在 Finder 中进入 `Applications`，右键点击 `Codex Synced.app`，选择“打开”，再确认打开。
4. 如果仍然被拦截，打开“系统设置” -> “隐私与安全性”，在“安全性”区域点击“仍要打开”或“打开”。
5. 如果提示“Codex Synced.app 已损坏，无法打开”，可以移除该 app 的下载隔离属性后再打开：

```bash
xattr -dr com.apple.quarantine "/Applications/Codex Synced.app"
```

如果你还没有拖入 `Applications`，也可以把命令里的路径换成 DMG 里或下载目录里的 app 路径。最稳妥的做法是在终端输入 `xattr -dr com.apple.quarantine ` 后，把 `Codex Synced.app` 从 Finder 拖到终端窗口自动填入路径。

不建议使用 `sudo spctl --master-disable` 这类全局关闭 Gatekeeper 的做法；它会降低整台 Mac 的安全保护。只对确认来源的这个 app 移除 quarantine 更克制。

参考资料：

- [Apple：安全打开 Mac 上的 App](https://support.apple.com/en-ca/102445)
- [Apple：打开来自未知开发者的 Mac App](https://support.apple.com/en-euro/guide/mac-help/mh40616/mac)
- [Apple：App 已被修改或损坏](https://support.apple.com/guide/mac-help/the-app-has-been-modified-or-damaged-mh40619/mac)

## 适合谁

- 你切换过 Codex 的官方 OAuth、OpenAI API Key 或第三方 API Provider。
- 你确认历史会话文件仍在本地，但 Codex 界面里看不到。
- 你希望先看清楚会改哪些记录，再决定是否修复。
- 你希望修复前自动备份，并且可以从备份恢复。

## 主要功能

- 自动识别当前 Codex Provider 和状态库。
- 同时检查 `.codex` 根目录和 `.codex/sqlite`，根据数据库及 WAL/SHM 活跃时间选择真正正在使用的 `state_*.sqlite`。
- Provider 对齐同时覆盖普通会话和归档会话，并同步 SQLite 与 rollout 首行 metadata。
- 兼容新版 `threads.name`、毫秒时间字段和 `created_at > updated_at` 的时区迁移异常。
- 流式改写大型 rollout 的首行，不把整份会话正文载入内存。
- 预览 SQLite Provider 错配、短标题、更新时间、rollout mtime、`session_index.jsonl` 和全局 UI 状态修复项。
- 修复前创建轻量备份或全量备份。
- 轻量备份保存必要回滚数据，全量备份额外保存 sessions。
- 支持从历史备份恢复。
- 中文优先，同时提供 English 界面。

## 使用流程

1. 打开 Codex Synced。
2. 查看首页识别到的 Provider、状态库和待修复数量。
3. 进入“待修复项”，确认变更预览。
4. 选择“轻量备份”或“全量备份”。
5. 点击“备份并修复”。
6. 修复完成后重新打开 Codex，侧边栏会话标题和排序应恢复正常。

![待修复项预览](docs/screenshots/pending-repairs-zh.png)

## 备份与恢复

每次真正写入前，Codex Synced 都会先创建备份。你可以在“备份”页查看已有备份，并在需要时恢复。

![备份管理](docs/screenshots/backups-zh.png)

默认保留：

- 轻量备份：5 份
- 全量备份：3 份

这些数量可以在设置中调整。

![设置](docs/screenshots/settings-zh.png)

## 安全边界

Codex Synced 的目标很窄：只修复会话历史的本地可见性。

它不会：

- 修改 OAuth Token
- 修改 API Key
- 修改第三方 API URL
- 修改 Provider 配置
- 修改会话正文
- 上传任何本地历史或配置

它会：

- 读取当前 Codex 配置中的根级 `model_provider`
- 读取本地状态数据库、会话索引、rollout metadata 和全局 UI 状态
- 在你确认后更新必要的侧边栏摘要字段
- 在写入前创建可恢复备份

## 常见问题

### 为什么需要先退出 Codex？

Codex 运行时可能正在读写本地状态文件。为了避免写入冲突，修复和恢复前需要先退出 Codex。

### 应该选轻量备份还是全量备份？

日常修复建议使用轻量备份，它保存恢复所需的关键文件，速度更快、占用更少。若你希望额外保存 sessions 目录，可以选择全量备份。

### 它会同步到云端吗？

不会。Codex Synced 只在本机工作，不提供云同步，也不会上传会话内容。

### 没有待修复项怎么办？

说明当前本地侧边栏摘要状态正常。之后如果 Codex 再次出现标题、排序或项目缺失问题，可以重新扫描。
