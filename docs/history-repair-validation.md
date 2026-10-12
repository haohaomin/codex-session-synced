# 对话入口修复：实现与验证记录

## 范围

macOS 1.4.0 实验性功能，独立于侧边栏修复。Windows 未移植。

只接受能够从原始根文件完整追溯到唯一末端的分页分支链。物理 ID 来自已识别的 rollout 文件名，逻辑 ID 必须与 session metadata 和状态库一致。`history_base` 的序号边界、父文件原始字节偏移和子文件首序号必须同时吻合。不选取“时间最新”的文件。

修复只更新一条 `threads.rollout_path`，并对所有列的 SQLite 存储类型及值进行前后对照。数据库触发器会阻断写入。每个原始文件先计算 SHA-256，在复制和提交前后重新检查；JSONL 保持字节一致。由于不会写入历史/日志库，不对它们做整库备份，也不声称跨库快照一致。

备份目录独立保存状态库 Backup API 快照、源文件、数据库试写副本和提交前操作意图。源文件副本用于证据保全；试写数据库仍保留真实绝对 rollout 路径，**不是用于启动客户端的完全隔离 Codex Home**。程序不会用试写数据库调用官方客户端。

撤销使用同样的事务内条件检查，只还原该入口字段；不回灌旧数据库。目标元数据或原文件有任何变化，或新增分支，均需重新调查。其他对话的新记录不影响安全撤销，也不会被覆盖。

## 2026-10-12 本地验证

- 34 个自动化测试通过（21 个新增对话修复测试、13 个原有回归测试）。
- Debug 与 Release 构建通过。
- 使用独立临时数据库及合成 JSONL 样本打开 Release 界面，检查「对话修复」入口、只读扫描、当前/建议路径、有效消息计数、确认弹窗和验收限制提示。
- 在 Codex Desktop 仍运行时点击测试样本的修复按钮，正确显示退出提示；只读复查测试库，入口未改变。
- 测试中未修改真实 Codex 对话库、未重启或终止用户的 Codex 进程。

自动测试覆盖唯一后继链、编辑替换、多级物理父分支、CRLF/UTF-8 字节长度、EOF 边界、丢失文件、缺失父分支、循环、多末端、未知文件名、非法 JSON、重复序号、50 字节偏移异常、过期元数据/文件、运行中拒绝写入、WAL 快照、事务后置检查失败回滚、完整修复/撤销、保留其他对话后续变化及阻止分页 Provider 首行改写。

## 构建环境

通常运行 `swift test` 和 `swift build -c release` 即可。本机 Command Line Tools 的默认 macOS 27 SDK 缺少 SwiftUI 宏插件，Testing 插件也不在默认搜索路径；本次没有更改系统工具链或项目默认设置，使用本机现有 26.5 SDK 与显式插件路径完成验证：

```sh
swift test \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing

swift build -c release \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
```

若要保留合成样本供界面检查，可在测试命令前设置 `CODEX_SYNCED_KEEP_TEST_FIXTURES=1`，并使用 `--filter scanIsReadOnlyAndExcludesSupersededMessages`。输出会给出临时目录。必须把测试应用的 Codex Home 和 SQLite Home 都指向该目录，不能把测试写入指向真实数据。

## 尚未完成的产品验收

- 没有自动对照官方 `thread/read` 和分页接口中的逐条正文、顺序及重复情况。
- 没有自动验证真实 Codex Desktop 重新打开及重启后的读取持久性。
- 没有实现 Windows 入口修复；Windows 安装包构建与原有自测由发布 CI 验证。

以上限制在 README、修复确认弹窗和成功提示中明确展示。文件未改动和入口写入成功，不等于客户端完整读取已验收。
