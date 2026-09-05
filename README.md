# Codex Synced

[English](README_EN.md) | 中文

Codex Synced 是一个 Windows / macOS 本地修复工具，用来解决 Codex Desktop 侧边栏会话历史不可见、标题显示为“新对话”、时间排序异常等本地状态问题。

它会预览需要修复的本地记录，并在备份后修复 SQLite 摘要、`session_index.jsonl`、rollout 文件 mtime 和 `.codex-global-state.json` 中影响侧边栏显示的字段。默认会把可恢复的普通会话（包括归档会话）及其 rollout metadata 对齐到当前根级 `model_provider`，解决切换官方或第三方 Provider 后历史被过滤的问题；也可以在设置中关闭跨 Provider 对齐，改为仅按 rollout 修正 SQLite。

它不是云同步工具，也不会上传你的会话。所有扫描、备份、修复都发生在本机。

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

1. 前往 [GitHub Releases](https://github.com/renhao12356578/codex-session-synced/releases/latest) 下载 `Codex-Synced-Windows-x64-1.3.0.msi`。
2. 退出 Codex。
3. 双击 MSI 完成安装，然后从开始菜单打开 `Codex Synced`。
4. 查看待修复项，选择备份模式，点击“备份并修复”。
5. 重新打开 Codex，检查历史会话。

Windows 版是完整桌面应用安装包，默认读取 `%USERPROFILE%\.codex`，并会自动识别当前活跃的状态库目录；也可以在设置中修改目录。Release 中也提供 `Codex-Synced-Windows-x64-1.3.0.zip`，用于不想安装时手动运行应用目录。

## macOS 下载与安装

1. 前往 [GitHub Releases](https://github.com/renhao12356578/codex-session-synced/releases/latest) 下载 `Codex-Synced-macOS-1.3.0.dmg`。
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
shasum -a 256 ~/Downloads/Codex-Synced-macOS-1.3.0.dmg
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
