import CodexSyncedCore
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        ZStack {
            DS.background
            .ignoresSafeArea()

            HStack(spacing: 0) {
                Sidebar()
                Divider().opacity(0.35)
                content
                    .id(viewModel.selectedSection)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .alert(viewModel.l10n.text("请先退出 Codex", "Quit Codex First"), isPresented: $viewModel.showingCodexRunningAlert) {
            Button(viewModel.l10n.text("好", "OK"), role: .cancel) {}
        } message: {
            Text(viewModel.l10n.text("为避免写入冲突，修复和恢复前需要先退出 Codex。", "Quit Codex before repair or restore to avoid state conflicts."))
        }
        .sheet(isPresented: $viewModel.showingRestoreConfirmation) {
            RestoreConfirmationView()
                .environmentObject(viewModel)
        }
        .overlay(alignment: .bottomTrailing) {
            if let notice = viewModel.notice {
                NoticeBanner(notice: notice) {
                    viewModel.dismissNotice()
                }
                .padding(20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.notice?.id)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.selectedSection {
        case .home:
            HomeView()
        case .pending:
            PendingRepairsView()
        case .history:
            HistoryRepairView()
        case .backups:
            BackupsView()
        case .settings:
            SettingsView()
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Namespace private var sidebarNamespace

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(DS.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Synced")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DS.ink)
                    Text(viewModel.l10n.text("会话历史修复", "History Repair"))
                        .font(.system(size: 12))
                        .foregroundStyle(DS.muted)
                }
            }
            .padding(.top, 22)
            .padding(.horizontal, 18)

            VStack(spacing: 6) {
                item(.home, "house", viewModel.l10n.text("首页", "Home"))
                item(.pending, "list.bullet.rectangle", viewModel.l10n.text("待修复项", "Pending"))
                item(.history, "text.bubble", viewModel.l10n.text("对话修复", "Chat Repair"))
                item(.backups, "externaldrive", viewModel.l10n.text("备份", "Backups"))
                item(.settings, "gearshape", viewModel.l10n.text("设置", "Settings"))
            }
            .padding(.horizontal, 12)

            Spacer()

            LanguageSwitch()
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
        .frame(width: 210)
        .background(DS.sidebar)
    }

    private func item(_ section: AppSection, _ image: String, _ title: String) -> some View {
        let selected = viewModel.selectedSection == section
        return Button {
            guard viewModel.selectedSection != section else { return }
            withAnimation(AppMotion.settle) {
                viewModel.selectedSection = section
            }
        } label: {
            Label(title, systemImage: image)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .symbolEffect(.bounce, value: selected)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .leading)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white)
                            .matchedGeometryEffect(id: "sidebar-selection", in: sidebarNamespace)
                            .shadow(color: DS.shadow.opacity(0.55), radius: 10, x: 0, y: 5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(DS.line)
                            )
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? DS.ink : DS.muted)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .modifier(SidebarHoverLift(enabled: !selected))
    }
}

private struct SidebarHoverLift: ViewModifier {
    @State private var isHovering = false
    var enabled: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovering && enabled ? Color.white.opacity(0.55) : Color.clear)
            )
            .offset(x: isHovering && enabled ? 2 : 0)
            .animation(AppMotion.quick, value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

struct LanguageSwitch: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            languageButton(.zh)
            languageButton(.en)
        }
        .padding(3)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(DS.line)
        )
    }

    private func languageButton(_ language: Language) -> some View {
        let selected = viewModel.settings.language == language
        return Button {
            guard viewModel.settings.language != language else { return }
            withAnimation(AppMotion.settle) {
                viewModel.settings.language = language
            }
        } label: {
            ZStack {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DS.blue)
                        .matchedGeometryEffect(id: "language-selection", in: namespace)
                }
                Text(language.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .white : DS.muted)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 26)
        }
        .buttonStyle(.plain)
        .buttonStyle(PressableButtonStyle())
    }
}
