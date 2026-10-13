import CodexSyncedCore
import SwiftUI

struct PendingRepairsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var showRepairPulse = false
    @State private var selectedPaginatedRepair: PaginatedProviderRepair?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HeaderView(
                    title: viewModel.l10n.text("待修复项", "Pending Repairs"),
                    subtitle: viewModel.l10n.text("修复前预览，不会写入数据，确认后先备份再修复。", "Dry-run preview. Confirming creates a backup before changes.")
                )

                summary
                backupChoice
                previewList
            }
            .padding(28)
        }
        .sheet(item: $selectedPaginatedRepair) { repair in
            VStack(alignment: .leading, spacing: 16) {
                Text(viewModel.l10n.text("确认分页 Provider 修复", "Confirm paginated Provider repair"))
                    .font(.title2)
                Text(displayTitle(repair.title, fallback: repair.threadID))
                    .font(.headline)
                RepairRiskCard(
                    tone: .warning,
                    title: viewModel.l10n.text("这是独立的第二阶段写入", "This is a separate second-stage write"),
                    message: viewModel.l10n.text("将改写分页 session_meta 首行，并同步 history_base、thread_turns 与 projection 偏移。不会拼接或重建正文；失败会从本次备份恢复。", "This rewrites paginated session_meta headers and synchronizes history_base, thread_turns, and projection offsets. Bodies are never concatenated or rebuilt; failures restore this backup.")
                )
                Text(viewModel.l10n.text("目标 Provider：\(repair.targetProvider)\nrollout 文件：\(repair.rolloutRepairs.count)\nturn 偏移：\(repair.turnOffsetRepairs.count)\nprojection 偏移：\(repair.projectionOffsetRepairs.count)", "Target Provider: \(repair.targetProvider)\nRollout files: \(repair.rolloutRepairs.count)\nTurn offsets: \(repair.turnOffsetRepairs.count)\nProjection offsets: \(repair.projectionOffsetRepairs.count)"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DS.muted)
                    .textSelection(.enabled)
                Text(viewModel.l10n.text("修复后仍需重新打开对话并重启 Codex，核对正文顺序、遗漏、重复和项目归属。", "After repair, reopen the chat and restart Codex to check order, omissions, duplicates, and project ownership."))
                    .foregroundStyle(DS.muted)
                HStack {
                    Spacer()
                    Button(viewModel.l10n.text("取消", "Cancel")) { selectedPaginatedRepair = nil }
                    Button(viewModel.l10n.text("备份并修复分页 Provider", "Back Up & Repair Paginated Provider")) {
                        selectedPaginatedRepair = nil
                        Task { await viewModel.repairPaginated(repair) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isBusy)
                }
            }
            .padding(24)
            .frame(width: 620)
        }
    }

    private var summary: some View {
        SoftPanel {
            VStack(spacing: 0) {
                row(viewModel.l10n.text("目标 Provider", "Target Provider"), viewModel.scanResult?.providerInfo.provider ?? "-")
                row(providerSummaryTitle, "\(viewModel.scanResult?.sqliteProviderUpdates.count ?? 0)")
                row(viewModel.l10n.text("待对齐 rollout Provider", "Rollout providers to align"), "\(viewModel.scanResult?.rolloutRepairs.count ?? 0)")
                row(viewModel.l10n.text("待写入短标题", "Sidebar title rows"), "\(viewModel.scanResult?.sqliteTitleRepairs.count ?? 0)")
                row(viewModel.l10n.text("待修复更新时间", "Timestamp rows"), "\((viewModel.scanResult?.sqliteTimestampRepairs.count ?? 0) + (viewModel.scanResult?.rolloutMtimeRepairs.count ?? 0))")
                row(viewModel.l10n.text("分页 Provider 需确认", "Paginated Provider review"), "\(viewModel.scanResult?.paginatedProviderWarnings.count ?? 0)")
                row(viewModel.l10n.text("可安全重算分页偏移", "Paginated repairs ready"), "\(viewModel.scanResult?.paginatedProviderRepairs.count ?? 0)")
                row(viewModel.l10n.text("待重建索引条目", "Index entries to rebuild"), "\(viewModel.scanResult?.indexRepairs.count ?? 0)")
                row(viewModel.l10n.text("全局 UI 状态变更", "Global UI state changes"), "\(viewModel.scanResult?.globalStateRepair?.changes.count ?? 0)", last: true)
            }
        }
    }

    private var backupChoice: some View {
        SoftPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(viewModel.l10n.text("备份模式", "Backup Mode"))
                            .font(.system(size: 16, weight: .semibold))
                        Text(viewModel.l10n.text("轻量备份只保存必要回滚数据；全量备份会额外保存 sessions。", "Lightweight stores rollback data; full also copies sessions."))
                            .font(.system(size: 13))
                            .foregroundStyle(DS.muted)
                    }
                    Spacer()
                    BackupModeSwitch(selection: $viewModel.selectedBackupMode, language: viewModel.settings.language)
                    .frame(width: 240)
                    PrimaryButton(
                        title: viewModel.l10n.text("备份并修复", "Back Up and Repair"),
                        systemImage: "checkmark.seal",
                        disabled: !(viewModel.scanResult?.hasRepairs ?? false) || viewModel.isBusy,
                        isLoading: viewModel.isBusy
                    ) {
                        showRepairPulse.toggle()
                        Task { await viewModel.repairNow() }
                    }
                    .symbolEffect(.bounce, value: showRepairPulse)
                }
                if let progress = viewModel.progress {
                    OperationProgressView(progress: progress, tint: DS.blue)
                }
            }
        }
        .modifier(HoverLift(y: 1.5))
    }

    private var previewList: some View {
        SoftPanel {
            VStack(alignment: .leading, spacing: 14) {
                Text(viewModel.l10n.text("预览", "Preview"))
                    .font(.system(size: 16, weight: .semibold))

                if let result = viewModel.scanResult, result.hasRepairs {
                    let rows = previewRows(result: result).prefix(10)
                    if rows.isEmpty {
                        EmptyState(
                            image: "doc.badge.gearshape",
                            title: viewModel.l10n.text("没有可预览的写入项", "No previewable writes"),
                            message: viewModel.l10n.text("确认后会先创建备份，再写入必要的侧边栏摘要数据。", "A backup is created before writing sidebar summary data."),
                            actionTitle: nil,
                            actionImage: "arrow.right",
                            action: nil
                        )
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 12) {
                            Image(systemName: item.icon)
                                .foregroundStyle(DS.blue)
                                .frame(width: 34, height: 34)
                                .background(DS.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(DS.ink)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(item.detail)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(DS.muted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()

                            Text(item.kind)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DS.muted)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .modifier(HoverLift(y: 1))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(AppMotion.smooth.delay(Double(index) * 0.035), value: rows.count)
                        Divider().opacity(0.35)
                    }
                    if previewRows(result: result).count > 10 {
                        Text(viewModel.l10n.text("还有 \(previewRows(result: result).count - 10) 条记录未显示。", "\(previewRows(result: result).count - 10) more rows hidden."))
                            .font(.system(size: 12))
                            .foregroundStyle(DS.muted)
                    }
                    warningRows(result: result)
                    paginatedRepairRows(result: result)
                } else {
                    if let result = viewModel.scanResult, !result.paginatedProviderWarnings.isEmpty || !result.paginatedProviderRepairs.isEmpty || !result.paginatedProviderDiagnostics.isEmpty {
                        warningRows(result: result)
                        paginatedRepairRows(result: result)
                    } else {
                        EmptyState(
                        image: "checkmark.circle",
                        title: viewModel.l10n.text("当前没有待修复项", "No pending repairs"),
                        message: viewModel.l10n.text("侧边栏会话摘要状态正常。", "Sidebar conversation summaries look healthy."),
                        actionTitle: viewModel.l10n.text("重新扫描", "Scan Again"),
                        actionImage: "magnifyingglass"
                    ) {
                        Task { await viewModel.scan() }
                    }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func warningRows(result: ScanResult) -> some View {
        if !result.paginatedProviderWarnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                RepairRiskCard(
                    tone: .warning,
                    title: viewModel.l10n.text("分页会话需要单独确认", "Paginated threads need separate review"),
                    message: viewModel.l10n.text("未通过完整分支和偏移校验的项目不会自动改写；通过校验的项目可在下方进入独立第二阶段修复。SQLite Provider 对齐不会被冒充为正文修复。", "Items that fail complete lineage and offset validation are never rewritten automatically; validated items can enter the separate second-stage repair below. SQLite alignment is not presented as a body repair.")
                )
                ForEach(result.paginatedProviderWarnings.prefix(10)) { warning in
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(displayTitle(warning.title, fallback: warning.threadID))
                            .lineLimit(1)
                        Spacer()
                        Text("\(warning.currentProvider) -> \(warning.targetProvider)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(DS.muted)
                    }
                }
            }
            .padding(.top, 8)
        }
        if !result.paginatedProviderDiagnostics.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                RepairRiskCard(
                    tone: .warning,
                    title: viewModel.l10n.text("分页诊断需要人工确认", "Paginated diagnostics need manual review"),
                    message: viewModel.l10n.text("检测到历史库或分支索引无法唯一解释。工具不会猜测活动入口，也不会改写这些文件。", "The history database or lineage index could not be explained uniquely. The tool will not guess an active entrypoint or rewrite these files.")
                )
                ForEach(Array(result.paginatedProviderDiagnostics.prefix(10).enumerated()), id: \.offset) { _, diagnostic in
                    Text(diagnostic)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DS.muted)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func paginatedRepairRows(result: ScanResult) -> some View {
        if !result.paginatedProviderRepairs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                RepairRiskCard(
                    tone: .info,
                    title: viewModel.l10n.text("分页 Provider 可安全重算", "Paginated Provider repairs are ready"),
                    message: viewModel.l10n.text("已验证唯一分支链、正文边界和历史库结构。确认后会先备份，再同步修改首行 metadata 与必要偏移。", "The unique lineage, body boundaries, and history schema passed validation. Confirmation backs up first, then updates metadata and required offsets together.")
                )
                ForEach(result.paginatedProviderRepairs) { repair in
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(DS.blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayTitle(repair.title, fallback: repair.threadID))
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(viewModel.l10n.text("\(repair.rolloutRepairs.count) 个 rollout · \(repair.turnOffsetRepairs.count) 个 turn 偏移 · \(repair.projectionOffsetRepairs.count) 个 projection 偏移", "\(repair.rolloutRepairs.count) rollout files · \(repair.turnOffsetRepairs.count) turn offsets · \(repair.projectionOffsetRepairs.count) projection offsets"))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(DS.muted)
                        }
                        Spacer()
                        Button(viewModel.l10n.text("预览并修复", "Review & Repair")) {
                            selectedPaginatedRepair = repair
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isBusy)
                    }
                    .padding(.vertical, 5)
                }
            }
            .padding(.top, 10)
        }
    }

    private func row(_ title: String, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .foregroundStyle(DS.muted)
                Spacer()
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.ink)
            }
            .padding(.vertical, 11)
            if !last { Divider().opacity(0.35) }
        }
    }

    private struct PreviewItem: Identifiable {
        var id: String
        var icon: String
        var kind: String
        var title: String
        var detail: String
    }

    private func previewRows(result: ScanResult) -> [PreviewItem] {
        var items: [PreviewItem] = []
        items += result.sqliteProviderUpdates.map {
            PreviewItem(
                id: "provider-\($0.thread.id)",
                icon: "cylinder.split.1x2",
                kind: viewModel.settings.alignProvidersForVisibility ? viewModel.l10n.text("Provider 对齐", "Provider Align") : "Provider",
                title: displayTitle($0.thread.title, fallback: $0.thread.id),
                detail: "\($0.thread.modelProvider) -> \($0.targetProvider)"
            )
        }
        items += result.rolloutRepairs.map {
            PreviewItem(
                id: "rollout-\($0.url.path)",
                icon: "doc.text.magnifyingglass",
                kind: viewModel.l10n.text("rollout Provider", "Rollout Provider"),
                title: displayTitle($0.sessionID, fallback: $0.url.lastPathComponent),
                detail: "\($0.currentProvider ?? "nil") -> \($0.targetProvider)"
            )
        }
        items += result.sqliteTitleRepairs.map {
            PreviewItem(
                id: "title-\($0.threadID)",
                icon: "text.badge.checkmark",
                kind: viewModel.l10n.text("标题", "Title"),
                title: displayTitle($0.targetTitle, fallback: $0.threadID),
                detail: displayTitle($0.currentTitle, fallback: viewModel.l10n.text("空标题", "empty title"))
            )
        }
        items += result.sqliteTimestampRepairs.map {
            PreviewItem(
                id: "time-\($0.threadID)",
                icon: "clock.arrow.circlepath",
                kind: viewModel.l10n.text("时间", "Time"),
                title: displayTitle($0.title, fallback: $0.threadID),
                detail: "\($0.currentUpdatedAtMs) -> \($0.targetUpdatedAtMs)"
            )
        }
        items += result.rolloutMtimeRepairs.map {
            PreviewItem(
                id: "mtime-\($0.rolloutPath)",
                icon: "doc.badge.clock",
                kind: "mtime",
                title: displayTitle($0.title, fallback: $0.threadID),
                detail: "\($0.currentMtimeMs) -> \($0.targetMtimeMs)"
            )
        }
        items += result.paginatedProviderWarnings.map {
            PreviewItem(
                id: "paginated-provider-\($0.threadID)",
                icon: "exclamationmark.triangle",
                kind: viewModel.l10n.text("需确认", "Review"),
                title: displayTitle($0.title, fallback: $0.threadID),
                detail: viewModel.l10n.text("分页 rollout：\($0.currentProvider) -> \($0.targetProvider)", "Paginated rollout: \($0.currentProvider) -> \($0.targetProvider)")
            )
        }
        items += result.indexRepairs.prefix(1).map {
            PreviewItem(
                id: "index-\($0.threadID)",
                icon: "list.bullet.rectangle",
                kind: viewModel.l10n.text("索引", "Index"),
                title: viewModel.l10n.text("重建 session_index.jsonl", "Rebuild session_index.jsonl"),
                detail: viewModel.l10n.text("\(result.indexRepairs.count) 条 resume-compatible 会话", "\(result.indexRepairs.count) resume-compatible threads")
            )
        }
        items += (result.globalStateRepair?.changes ?? []).enumerated().map { offset, change in
            PreviewItem(
                id: "global-\(offset)",
                icon: "sidebar.leading",
                kind: viewModel.l10n.text("UI 状态", "UI State"),
                title: change,
                detail: ".codex-global-state.json"
            )
        }
        return items
    }

    private var providerSummaryTitle: String {
        viewModel.settings.alignProvidersForVisibility
            ? viewModel.l10n.text("对齐到当前 Provider 的 SQLite 记录", "SQLite rows aligned to active provider")
            : viewModel.l10n.text("按 rollout 修正 Provider 的 SQLite 记录", "SQLite provider rows matched to rollout")
    }

    private func displayTitle(_ value: String, fallback: String) -> String {
        let title = value
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return title.isEmpty ? fallback : title
    }
}
