import CodexSyncedCore
import SwiftUI

struct BackupsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var deleting: ManagedBackup?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HeaderView(
                    title: viewModel.l10n.text("备份", "Backups"),
                    subtitle: viewModel.l10n.text("普通备份和对话修复备份可逐条删除到废纸篓；恢复或撤销前需退出 Codex。", "Move individual ordinary or chat-repair backups to Trash. Quit Codex before restore or rollback.")
                )

                SoftPanel {
                    VStack(spacing: 12) {
                        HStack {
                            Text(viewModel.l10n.text("本地备份", "Local Backups"))
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                            SecondaryButton(title: viewModel.l10n.text(viewModel.loadingBackups ? "读取中…" : "刷新", viewModel.loadingBackups ? "Loading…" : "Refresh"), systemImage: "arrow.clockwise") {
                                Task { await viewModel.refreshBackups() }
                            }.disabled(viewModel.loadingBackups || viewModel.isBusy)
                            SecondaryButton(title: viewModel.l10n.text("打开备份目录", "Open Folder"), systemImage: "folder") {
                                viewModel.openBackupDirectory()
                            }
                        }

                        ForEach(viewModel.backupWarnings, id: \.self) { warning in
                            Text(warning).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        if viewModel.loadingBackups && viewModel.managedBackups.isEmpty {
                            ProgressView()
                        } else if !viewModel.managedBackups.isEmpty {
                            ForEach(viewModel.managedBackups) { item in
                                VStack(alignment: .leading, spacing: 8) {
                                    if let backup = item.backup {
                                        BackupRow(backup: backup, compact: false)
                                    } else {
                                        Text(viewModel.l10n.text("对话修复备份", "Chat Repair Backup")).font(.headline)
                                        Text(item.title).lineLimit(2)
                                        Text(item.createdAt.formatted()).font(.caption)
                                    }
                                    Text(item.directory.path).font(.caption.monospaced()).foregroundStyle(DS.muted).textSelection(.enabled)
                                    HStack {
                                        if let backup = item.backup {
                                            SecondaryButton(title: viewModel.l10n.text("恢复此备份", "Restore"), systemImage: "arrow.counterclockwise") {
                                                viewModel.selectedBackupForRestore = backup
                                                viewModel.showingRestoreConfirmation = true
                                            }.disabled(viewModel.isBusy)
                                        } else {
                                            Button(viewModel.l10n.text("前往对话修复查看撤销", "View Rollback in Chat Repair")) {
                                                viewModel.selectedSection = .history
                                            }
                                        }
                                        Spacer()
                                        Button(role: .destructive) { deleting = item } label: {
                                            Label(viewModel.l10n.text("删除备份…", "Delete Backup…"), systemImage: "trash")
                                        }.disabled(viewModel.isBusy || viewModel.loadingBackups)
                                    }
                                }.padding(12)
                                Divider()
                            }
                        } else {
                            HStack {
                                Spacer(minLength: 0)
                                EmptyState(
                                    image: "externaldrive.badge.plus",
                                    title: viewModel.l10n.text("暂无备份", "No backups yet"),
                                    message: viewModel.l10n.text("只有存在实际待修复项并执行“备份并修复”时，应用才会创建备份。轻量备份默认保留 5 份，全量备份默认保留 3 份。", "Backups are created only when repairs are applied. Lightweight keeps 5 by default; full keeps 3 by default."),
                                    actionTitle: viewModel.l10n.text("查看待修复项", "View Pending"),
                                    actionImage: "list.bullet.rectangle"
                                ) {
                                    viewModel.selectedSection = .pending
                                }
                                .frame(maxWidth: 560)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
            }
            .padding(28)
        }
        .task(id: viewModel.settings.codexHome) { await viewModel.refreshBackups() }
        .alert(viewModel.l10n.text("将这份备份移到废纸篓？", "Move this backup to Trash?"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button(viewModel.l10n.text("取消", "Cancel"), role: .cancel) { deleting = nil }
            Button(viewModel.l10n.text("移到废纸篓", "Move to Trash"), role: .destructive) {
                if let item = deleting { Task { await viewModel.deleteBackup(item) } }
                deleting = nil
            }.disabled(viewModel.isBusy)
        } message: {
            Text((deleting.map { "\($0.createdAt.formatted())\n\($0.directory.path)\n\n" } ?? "") + viewModel.l10n.text("只移走这一份备份，不修改当前会话。移走后不能直接恢复或撤销对应修复；可在 Finder 废纸篓中放回原位置后刷新。清空废纸篓后将无法恢复。", "Only this backup is moved; live chats are not modified. Restore/rollback will be unavailable until you put it back from Finder's Trash and refresh. Emptying Trash makes deletion permanent."))
        }
    }
}

struct BackupRow: View {
    var backup: BackupRecord
    var compact: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: backup.mode == .full ? "externaldrive.fill" : "externaldrive")
                .foregroundStyle(DS.blue)
                .frame(width: 34, height: 34)
                .background(DS.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(backup.createdAt.shortDateTime)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.ink)
                Text("\(backup.mode.zhTitle) · Provider \(backup.targetProvider) · \(backup.sizeBytes.fileSizeText)")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.muted)
                if !compact {
                    Text("SQLite \(backup.summary.sqliteProviderUpdates) · Rollout \(backup.summary.rolloutUpdates) · Index \(backup.summary.indexInsertions)")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.muted)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(DS.subtlePanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DS.line)
        )
        .modifier(HoverLift(y: compact ? 0 : 1.5))
    }
}
