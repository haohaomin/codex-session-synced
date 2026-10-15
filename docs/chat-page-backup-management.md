# 对话页反馈与备份删除

## 已确认的原因

用户截图不是全局点击失效：扫描已返回“目录应只有一个 state 数据库”的错误。只读检查确认本机根目录和 sqlite 子目录各有一个 `state_5.sqlite`。旧界面没有候选文件选择入口，反复点击只得到同一错误；打开不存在的修复记录目录又忽略了系统返回值，造成无反应的观感。

## 实现

1. 对话页显示候选数据库。显式 `historyDatabase` 仅用于该页；候选消失、链接或越界则拒绝，自动模式仍要求唯一文件。修复及撤销再次扫描并验证所选数据库，禁止在另一个数据库上套用旧预览。
2. 扫描独立显示进行中、失败及完成数量；重复扫描禁用。不存在的目录不伪造成功，不为“打开目录”悄悄创建空修复记录。记录可独立于扫描加载。
3. 备份页独立列出两类备份、路径和时间。取消确认不写入；确认删除重新读取描述文件，核对哈希及目录身份、当前位置。未知或损坏目录展示警告，不提供强制删除。
4. macOS 使用系统 Trash；Windows 采用同卷目录移动到 `codex-synced-deleted-backups`，随机前缀避免覆盖旧的已删除备份。Windows 删除成功显示目标路径；取回时需恢复原路径和原文件夹名。两端均不清空回收目录、不使用永久递归删除作为失败回退。
5. 修改仅涉及明确的备份及工具设置；无对话正文拼接、数据库搬迁或活动库重写。操作过程中 UI 禁止并行修复/恢复/删除。

## 验证记录（2026-10-15）

- macOS 隔离 QA 应用使用独立 bundle ID、设置及临时 Home，包含两个测试状态库、一个测试分页对话和自建备份。
- 实际点击确认：自动模式报告多个状态库；候选列表可选；选定文件后扫描显示检查 1 个分页对话；记录目录不存在时显示明确原因；创建测试记录后“打开修复记录”在 Finder 打开正确的测试目录。
- 备份页实际点击确认：显示两类备份；取消删除保留普通备份；确认后系统 Trash 中可见测试备份，列表为空；将测试备份放回后刷新重新显示。原测试备份已放回，未清空 Trash。
- 两个测试状态库与 JSONL 在上述扫描/删除前后 SHA-256 一致。没有对真实用户备份执行删除。
- Swift 回归覆盖明确数据库选择、其他库不变、拒绝错误库撤销、丢失/链接选择、扫描歧义时仍管理修复备份，以及删除/恢复、失效描述文件、根目录/链接拒绝和 Trash 失败不永久删除。
- Windows 备份逻辑使用独立 net8.0 程序在本机执行（34 个断言）；WPF 交叉编译验证。Windows 自测新增多库选择用例，需 Windows 桌面运行时执行；未宣称本机已运行该自测或 Windows UI。
- 最终验证：Swift 57 项测试通过，macOS Release 构建通过（原有 SDK 搜索目录 warning 不阻断构建）；Windows 34 个备份断言、58 个更新检查回归断言通过，WPF Release 交叉编译 0 warning / 0 error；`git diff --check` 通过。隔离 QA 应用已正常退出，正式应用未替换。

## 边界

上述验收运行独立测试构建；用户随后授权以 1.10.0 发布并替换本机应用，发布需经过两平台 CI 门禁。Windows 原生 UI/系统环境仍需 Windows 实机冒烟验证。备份删除不会修复用户当前真实数据库的入口，也不代表所有真实对话正文已验收。

```sh
swift test --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
swift build -c release --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
dotnet run --project Windows/BackupTests/BackupTests.csproj -c Release
dotnet build Windows/CodexSynced.Windows/CodexSynced.Windows.csproj -c Release -p:EnableWindowsTargeting=true -p:GenerateWindowsIcon=false
```
