# 应用更新方案

## 目标与阶段

为原生 SwiftUI macOS 和 WPF Windows 增加统一的更新入口，更新 Codex Synced 本身，不更新 Codex，也不修改其会话数据。

第一阶段（本次实现）：设置页手动检查、默认关闭的启动检查、当前/最新版本、纯文本发布说明、显式打开匹配版本的 GitHub 发布页。用户自行下载和安装；程序不下载、执行安装器、终止进程或覆盖安装目录。

第二阶段（未实现）：签名更新清单、内置公钥、下载后验签、重新确认所选版本、退出协调、原应用备份、替换、新进程 ready 握手和失败回滚。现有发布只有 SHA256SUMS，不能替代独立签名，因此第一阶段不提供“自动安装”按钮。

## 检查协议

- 固定来源：`https://api.github.com/repos/haohaomin/codex-session-synced/releases/latest`，不跟随 API 重定向，不使用本地 GitHub token。
- 只接受普通稳定 Release，严格解析 `vMAJOR.MINOR.PATCH`，按数字比较；相同/较旧版本不提供更新，开发版无法识别版本时不猜测。
- 校验发布页为同仓库对应 tag 的 HTTPS URL，平台资产名称、上传状态、正数大小及下载 URL 必须匹配。macOS 要求 DMG；Windows 要求 x64 MSI 和 ZIP。Windows 用户根据当前安装方式手动选包，不自动解压 ZIP。
- 20 秒总超时，响应体上限 1 MiB，不接受错误 HTTP 状态、损坏 JSON、预发布、重复/缺少资产或陌生下载地址。
- 检查只获取 Release JSON，不请求安装包。发布说明仅按文本显示，不执行或自动打开其中链接。

## 状态与数据边界

- 空闲 → 检查中 → 有更新 / 无更新 / 检查失败。同一窗口合并重复检查；失败清除旧候选，不能把失败显示为“已是最新”。
- 自动检查每次启动至多一次且默认关闭；失败不弹窗、不打断修复。手动检查展示原因，允许重试。
- 点击“打开下载页面”才启动系统浏览器；明确提示先完成修复、正常退出本工具，保留旧应用和数据后手动安装。打开页面不表示安装成功。
- 不读取/改写 `.codex`、SQLite/WAL、JSONL、API key、Provider 配置或备份。只持久化检查开关，不改变原设置格式中的其他字段。
- 不发布、不提交签名密钥、不替换本机正在运行的应用。

## 验收

两平台离线测试覆盖数字版本比较、非法版本、草稿/预发布、错误来源、缺少/重复/未上传/空资产、HTTP 失败、大小限制和网络异常。Swift 全套回归测试、macOS Release 构建及 Windows 交叉编译。Windows 更新检查逻辑通过独立 net8.0 测试程序运行，WPF 交互仍需 Windows 实机验收。

真实安装后的版本、重新启动和数据保留属于用户手动安装的验收，不由本阶段冒充已完成。

## 本地验证记录（2026-10-14）

- Swift：49 项测试通过（新增 8 项更新测试，其中版本和网络失败使用参数化样本），包含现有修复回归；macOS Release 构建通过。Command Line Tools 仍有缺失框架搜索目录的 linker warning，未阻断构建。
- Windows：独立更新测试程序 58 个断言通过；WPF Release 在 macOS 交叉编译通过，0 warning / 0 error。尚未在 Windows 实机操作更新界面。
- 只读检查 GitHub API：当前稳定版本 `v1.8.1`，发布页与 macOS DMG、Windows x64 MSI/ZIP 的名称、状态及地址符合规则。未下载安装包。
- `git diff --check` 通过。没有修改实际会话数据，没有替换本机已安装应用，也没有提交或发布。
- 未完成：两端完整 UI 点击验收，以及真实安装、重启和更新前后数据对照；不能据上述测试宣称这些已通过。

### 1.9.0 发布准备补充

用户随后授权本机替换、提交和发布。macOS 本机构建的 1.9.0 已从 1.6.0 升级，旧应用完整保留用于回退；安装后的可执行文件与构建产物 SHA-256 一致。替换前后 `config.toml` 和工具偏好设置文件哈希一致，未改写会话数据库。新应用成功启动，设置页显示 1.9.0，手动检查完成并显示“没有更新的稳定版本”（当时远端最新为 1.8.1，未提示降级）。这些是本机安装及基础 UI 冒烟验证，不包含 Windows 实机、未来版本可用时的下载页确认流程或全部会话的逐条正文验收。发布仍由两平台 CI 门禁控制。

可重复的本地命令：

```sh
swift test --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
swift build -c release --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
dotnet run --project Windows/UpdateTests/UpdateTests.csproj -c Release
dotnet build Windows/CodexSynced.Windows/CodexSynced.Windows.csproj -c Release -p:EnableWindowsTargeting=true -p:GenerateWindowsIcon=false
```
