import CodexSyncedCore
import SwiftUI

struct HistoryRepairView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var selected: HistoryDiagnosis?
    @State private var rollback: HistoryRepairRecord?

    private func t(_ zh: String, _ en: String) -> String { model.l10n.text(zh, en) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderView(title: t("对话诊断与修复", "Chat Diagnosis & Repair"),
                    subtitle: t("实验性 · 针对原文件仍在、后续消息不显示的分页对话。", "Experimental · For paginated chats whose later messages are hidden but files still exist."))
                SoftPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(t("只改读取入口，不拼接正文", "Repair the entrypoint, never concatenate messages"))
                            .font(.headline)
                        Text(t("扫描只读。修复或撤销前必须退出 Codex；逐条预览并确认，不批量处理。多个末端、缺失文件、偏移不一致均需人工检查。", "Scanning is read-only. Quit Codex before repair or rollback. Review one chat at a time. Multiple tips, missing files and offset mismatches require manual review."))
                            .foregroundStyle(DS.muted)
                        RepairRiskCard(
                            tone: .info,
                            title: t("验收边界", "Verification boundary"),
                            message: t("文件哈希、序号和字节边界通过，只代表入口修复安全；重新打开对话并重启 Codex 后，仍需人工核对正文顺序、遗漏、重复和项目归属。", "Passing file hashes, ordinals and byte boundaries proves the entrypoint change is safe; reopen the chat and restart Codex to verify message order, omissions, duplicates and project ownership." )
                        )
                        HStack {
                            Button(t("只读扫描", "Read-only Scan")) { Task { await model.scanHistory() } }
                                .buttonStyle(.borderedProminent).disabled(model.isBusy)
                            if model.isBusy { ProgressView().controlSize(.small) }
                            Button(t("打开修复记录", "Open Repair Records")) {
                                model.service.openDirectory(HistoryRepairService().backupRoot(settings: model.settings))
                            }
                        }
                        if let message = model.historyMessage { Text(message).textSelection(.enabled) }
                    }
                }
                if let scan = model.historyScan {
                    Text("SQLite: \(scan.database.path)").font(.caption).textSelection(.enabled)
                    ForEach(scan.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                    if scan.diagnoses.isEmpty {
                        Text(t("未发现可识别的分页对话。本功能不处理旧格式，也不代表全部对话已通过检查。", "No recognized paginated chats. Legacy formats are outside this feature; this is not an all-clear."))
                    }
                    ForEach(scan.diagnoses.sorted { ($0.canRepair ? 0 : 1, $0.id) < ($1.canRepair ? 0 : 1, $1.id) }) { item in
                        diagnosisCard(item)
                    }
                }
                if !model.historyRecords.isEmpty {
                    Text(t("修复记录与安全撤销", "Repair Records & Safe Rollback")).font(.headline)
                    Text(t("记录包含提交前写入的操作意图，不等于修复成功。撤销仅在目标记录和文件均未再变化时可执行，避免覆盖新消息。备份含私人对话，不自动清理。", "Records include pre-commit intent, not proof of success. Rollback requires unchanged metadata and files to protect new messages. Backups contain private chats and are never auto-pruned."))
                        .font(.caption).foregroundStyle(DS.muted)
                    ForEach(model.historyRecords) { record in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(record.title).lineLimit(1)
                                Text(record.createdAt.formatted()).font(.caption)
                            }
                            Spacer()
                            Button(t("撤销入口修改…", "Revert entrypoint…")) { rollback = record }
                                .disabled(model.isBusy)
                        }
                    }
                }
            }.padding(28)
        }
        .sheet(item: $selected) { item in
            VStack(alignment: .leading, spacing: 16) {
                Text(t("确认最小修复", "Confirm Minimal Repair")).font(.title2)
                Text(item.title).font(.headline)
                Text("\(item.currentPath)\n↓\n\(item.proposedPath ?? "")")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text(t("先备份含 WAL 的状态库与原始分支文件，在数据库副本试写。真实数据只改这一条 rollout_path，保留全部其他字段。不会改写历史库、侧边栏或正文。", "Back up the state database including WAL and the original branch files; trial the update on a database copy. Change only this rollout_path. Preserve every other field, the history database, sidebar and messages."))
                Text(t("文件完整性校验不等于客户端逐条读取验证，修复后仍需重新打开与重启检查。", "File-integrity checks are not client message verification. Reopen and restart checks are still required."))
                    .foregroundStyle(.orange)
                HStack {
                    Spacer()
                    Button(t("取消", "Cancel")) { selected = nil }
                    Button(t("备份并修复入口", "Back Up & Repair Entrypoint")) {
                        selected = nil
                        Task { await model.repairHistory(item) }
                    }.buttonStyle(.borderedProminent).disabled(model.isBusy)
                }
            }.padding(24).frame(width: 640)
        }
        .alert(t("撤销这一条入口修改？", "Revert this entrypoint change?"), isPresented: Binding(
            get: { rollback != nil }, set: { if !$0 { rollback = nil } }
        )) {
            Button(t("取消", "Cancel"), role: .cancel) { rollback = nil }
            Button(t("检查并撤销", "Check & Revert")) {
                if let record = rollback { Task { await model.rollbackHistory(record) } }
                rollback = nil
            }
        } message: {
            Text(t("不会恢复整库；只在文件和目标记录未变化时还原旧入口。请先退出 Codex。", "Never restores the whole database; reverts only if target metadata and files are unchanged. Quit Codex first."))
        }
    }

    private func diagnosisCard(_ item: HistoryDiagnosis) -> some View {
        SoftPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).font(.headline).lineLimit(2)
                Text(item.id).font(.caption.monospaced()).textSelection(.enabled)
                Text(item.detail).foregroundStyle(item.canRepair ? DS.blue : DS.muted)
                Text(t("当前入口", "Current entrypoint") + ": " + item.currentPath)
                    .font(.caption.monospaced()).textSelection(.enabled)
                if let path = item.proposedPath {
                    Text(t("建议入口", "Proposed entrypoint") + ": " + path)
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text(t("有效继承范围内 message 记录：\(item.messageCount)（非客户端轮数）", "Message records in effective lineage: \(item.messageCount) (not client turns)"))
                        .font(.caption)
                    Button(t("预览并修复这一条…", "Review and repair this chat…")) { selected = item }
                        .disabled(model.isBusy)
                }
            }
        }
    }
}
