import SwiftUI
import CodexSyncedCore

enum DS {
    static let blue = Color(red: 0.02, green: 0.37, blue: 0.92)
    static let ink = Color(red: 0.08, green: 0.09, blue: 0.12)
    static let muted = Color(red: 0.43, green: 0.46, blue: 0.52)
    static let background = Color(red: 0.965, green: 0.972, blue: 0.984)
    static let sidebar = Color(red: 0.985, green: 0.988, blue: 0.994)
    static let panel = Color.white
    static let subtlePanel = Color(red: 0.985, green: 0.988, blue: 0.994)
    static let line = Color.black.opacity(0.075)
    static let ok = Color(red: 0.05, green: 0.50, blue: 0.30)
    static let warn = Color(red: 0.82, green: 0.38, blue: 0.06)
    static let shadow = Color(red: 0.10, green: 0.14, blue: 0.22).opacity(0.08)
}

enum AppMotion {
    static let quick = Animation.snappy(duration: 0.16)
    static let smooth = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let settle = Animation.spring(response: 0.44, dampingFraction: 0.84)
    static let playful = Animation.spring(response: 0.42, dampingFraction: 0.68)
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(AppMotion.quick, value: configuration.isPressed)
    }
}

struct HoverLift: ViewModifier {
    @State private var isHovering = false
    var y: CGFloat = 2

    func body(content: Content) -> some View {
        content
            .offset(y: isHovering ? -y : 0)
            .scaleEffect(isHovering ? 1.006 : 1)
            .shadow(color: DS.shadow.opacity(isHovering ? 0.9 : 0), radius: isHovering ? 12 : 0, x: 0, y: isHovering ? 6 : 0)
            .animation(AppMotion.smooth, value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

struct SoftPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(DS.line)
            )
            .shadow(color: DS.shadow, radius: 18, x: 0, y: 8)
    }
}

enum RepairCardTone {
    case info
    case success
    case warning

    var tint: Color {
        switch self {
        case .info: DS.blue
        case .success: DS.ok
        case .warning: DS.warn
        }
    }

    var icon: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }
}

struct RepairRiskCard: View {
    var tone: RepairCardTone
    var title: String
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tone.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tone.tint)
                .frame(width: 32, height: 32)
                .background(tone.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.ink)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tone.tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tone.tint.opacity(0.18))
        )
    }
}

struct PrimaryButton: View {
    var title: String
    var systemImage: String
    var disabled = false
    var isLoading = false
    var action: () -> Void
    @State private var isHovering = false
    @State private var tapPulse = false

    var body: some View {
        Button {
            tapPulse.toggle()
            action()
        } label: {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: systemImage)
                        .symbolEffect(.bounce, value: tapPulse)
                }
                Text(title)
            }
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 16)
                .frame(minWidth: 128, minHeight: 38)
                .foregroundStyle(.white)
                .background(disabled ? Color.gray.opacity(0.42) : DS.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(isHovering ? 0.42 : 0.0))
                )
                .shadow(color: DS.blue.opacity(!disabled && isHovering ? 0.25 : 0), radius: 12, x: 0, y: 5)
                .brightness(isHovering && !disabled ? 0.035 : 0)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(disabled || isLoading)
        .onHover { hovering in
            isHovering = hovering && !disabled && !isLoading
        }
        .animation(AppMotion.quick, value: disabled)
        .animation(AppMotion.quick, value: isLoading)
        .animation(AppMotion.quick, value: isHovering)
    }
}

struct SecondaryButton: View {
    var title: String
    var systemImage: String
    var action: () -> Void
    @State private var isHovering = false
    @State private var tapPulse = false

    var body: some View {
        Button {
            tapPulse.toggle()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 15)
                .frame(minHeight: 36)
                .foregroundStyle(isHovering ? DS.blue : DS.ink)
                .background(isHovering ? Color.white : DS.subtlePanel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isHovering ? DS.blue.opacity(0.22) : DS.line)
                )
                .shadow(color: DS.shadow.opacity(isHovering ? 0.55 : 0), radius: isHovering ? 10 : 0, x: 0, y: isHovering ? 5 : 0)
                .symbolEffect(.bounce, value: tapPulse)
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(AppMotion.quick, value: isHovering)
    }
}

struct BackupModeSwitch: View {
    @Binding var selection: BackupMode
    var language: Language
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            button(.lightweight)
            button(.full)
        }
        .padding(3)
        .background(DS.subtlePanel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DS.line)
        )
        .animation(AppMotion.smooth, value: selection)
    }

    private func button(_ mode: BackupMode) -> some View {
        let selected = selection == mode
        return Button {
            withAnimation(AppMotion.settle) {
                selection = mode
            }
        } label: {
            ZStack {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.blue)
                        .matchedGeometryEffect(id: "backup-mode-selection", in: namespace)
                        .shadow(color: DS.blue.opacity(0.18), radius: 8, x: 0, y: 4)
                }
                Text(language == .zh ? mode.zhTitle : mode.enTitle)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .white : DS.muted)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
        }
        .buttonStyle(.plain)
        .buttonStyle(PressableButtonStyle())
    }
}

struct CounterControl: View {
    @Binding var value: Int
    var range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 8) {
            smallButton("minus") {
                value = max(range.lowerBound, value - 1)
            }
            Text("\(value)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(DS.ink)
                .frame(width: 28)
                .contentTransition(.numericText())
            smallButton("plus") {
                value = min(range.upperBound, value + 1)
            }
        }
        .padding(4)
        .background(DS.subtlePanel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DS.line)
        )
        .animation(AppMotion.smooth, value: value)
    }

    private func smallButton(_ image: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.ink)
                .frame(width: 24, height: 24)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(DS.line)
                )
        }
        .buttonStyle(.plain)
        .buttonStyle(PressableButtonStyle())
    }
}

struct AnimatedToggle: View {
    @Binding var isOn: Bool
    @Namespace private var namespace

    var body: some View {
        Button {
            withAnimation(AppMotion.playful) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? DS.blue : Color.black.opacity(0.08))
                    .overlay(Capsule().strokeBorder(isOn ? DS.blue.opacity(0.28) : DS.line))
                Circle()
                    .fill(Color.white)
                    .matchedGeometryEffect(id: "toggle-thumb", in: namespace)
                    .frame(width: 18, height: 18)
                    .shadow(color: Color.black.opacity(0.16), radius: 4, x: 0, y: 2)
                    .padding(3)
            }
            .frame(width: 46, height: 24)
        }
        .buttonStyle(.plain)
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text(isOn ? "On" : "Off"))
        .accessibilityValue(Text(isOn ? "1" : "0"))
    }
}

struct EmptyState: View {
    var image: String
    var title: String
    var message: String
    var actionTitle: String?
    var actionImage: String
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: image)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DS.blue)
                .frame(width: 42, height: 42)
                .background(DS.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DS.ink)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(DS.muted)
                .lineLimit(3)
            if let actionTitle, let action {
                SecondaryButton(title: actionTitle, systemImage: actionImage, action: action)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

struct NoticeBanner: View {
    var notice: AppNotice
    var dismiss: () -> Void

    private var tint: Color {
        switch notice.tone {
        case .info: DS.blue
        case .success: DS.ok
        case .warning: DS.warn
        }
    }

    private var icon: String {
        switch notice.tone {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            if notice.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
                    .padding(.top, 2)
            } else {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.ink)
                Text(notice.message)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.muted)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.muted)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
        .padding(13)
        .frame(width: 360)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.22))
        )
        .shadow(color: DS.shadow, radius: 18, x: 0, y: 8)
    }
}

struct ActivityStrip: View {
    var tint: Color = DS.blue
    @State private var isMoving = false

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(tint.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.clear, tint.opacity(0.85), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(proxy.size.width * 0.42, 90))
                        .offset(x: isMoving ? proxy.size.width : -max(proxy.size.width * 0.42, 90))
                }
                .clipShape(Capsule())
                .onAppear {
                    isMoving = false
                    withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                        isMoving = true
                    }
                }
        }
        .frame(height: 3)
    }
}

struct OperationProgressView: View {
    var progress: OperationProgress
    var tint: Color = DS.blue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(progress.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.ink)
                Spacer()
                if let fraction = progress.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(tint)
                }
            }
            ProgressView(value: progress.fraction ?? 0)
                .tint(tint)
                .controlSize(.small)
            Text(progress.detail)
                .font(.system(size: 12))
                .foregroundStyle(DS.muted)
                .lineLimit(2)
        }
        .padding(12)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.14)))
    }
}

struct MetricTile: View {
    var title: String
    var value: String
    var caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.muted)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .contentTransition(.numericText())
                .animation(AppMotion.smooth, value: value)
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(DS.muted)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(DS.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(DS.line)
        )
        .shadow(color: DS.shadow.opacity(0.65), radius: 12, x: 0, y: 5)
        .animation(AppMotion.smooth, value: value)
        .modifier(HoverLift(y: 1.5))
    }
}

extension Date {
    var shortDateTime: String {
        formatted(date: .abbreviated, time: .shortened)
    }
}

extension Int64 {
    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
