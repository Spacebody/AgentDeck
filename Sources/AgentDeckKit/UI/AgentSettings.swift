// Agent 级设置的唯一注册表与管理页。新增 Agent 时只需在 Catalog 增加一项，
// 设置入口、面板显示、状态栏参与项和主题色编辑都会自动生成。
import SwiftUI

enum SettingsPage: Equatable {
    case main
    case agents

    var titleKey: String {
        switch self {
        case .main: return "header.settings"
        case .agents: return "set.agentManager"
        }
    }
}

struct AgentSettingDescriptor: Identifiable, Equatable {
    let id: String
    let name: String
    let brand: Brand
    let showKey: String
    let menubarKey: String
    let colorKey: String
    let defaultColor: String
}

enum AgentSettingsCatalog {
    static let all: [AgentSettingDescriptor] = [
        .init(id: "claude", name: "Claude", brand: .claude,
              showKey: "show_claude", menubarKey: "menubar_claude",
              colorKey: "color_claude", defaultColor: "#ff9d7a"),
        .init(id: "codex", name: "Codex", brand: .codex,
              showKey: "show_codex", menubarKey: "menubar_codex",
              colorKey: "color_codex", defaultColor: "#8be9e2"),
        .init(id: "qoder", name: "Qoder", brand: .qoder,
              showKey: "show_qoder", menubarKey: "menubar_qoder",
              colorKey: "color_qoder", defaultColor: "#a78bfa"),
    ]

    static let visibilityKeys = Set(all.map(\.showKey))
    static let menubarKeys = Set(all.map(\.menubarKey))
    static let colorKeys = Set(all.map(\.colorKey))

    static func enabledCount(in values: [String: SettingValue]) -> Int {
        all.reduce(0) { $0 + ((values[$1.showKey]?.boolVal ?? true) ? 1 : 0) }
    }
}

struct AgentManagerSummary: View {
    let values: [String: SettingValue]

    var body: some View {
        HStack(spacing: 8) {
            Text(L("set.agentEnabledCount", [
                "enabled": "\(AgentSettingsCatalog.enabledCount(in: values))",
                "total": "\(AgentSettingsCatalog.all.count)",
            ]))
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.ink2)

            HStack(spacing: -3) {
                ForEach(Array(AgentSettingsCatalog.all.prefix(3))) { agent in
                    Circle()
                        .fill(color(for: agent))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.28), lineWidth: 1))
                }
            }
            .accessibilityHidden(true)

            if AgentSettingsCatalog.all.count > 3 {
                Text("+\(AgentSettingsCatalog.all.count - 3)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.ink3)
        }
    }

    private func color(for agent: AgentSettingDescriptor) -> Color {
        Color(hexString: values[agent.colorKey]?.stringVal ?? "")
            ?? Color(hexString: agent.defaultColor)
            ?? agent.brand.accent
    }
}

struct AgentManagerView: View {
    let values: [String: SettingValue]
    let onSet: (String, SettingValue) -> Void
    let onResetColors: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("set.agentManagerHint"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(AgentSettingsCatalog.all.enumerated()), id: \.element.id) { index, agent in
                    agentRow(agent)
                    if index < AgentSettingsCatalog.all.count - 1 {
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
            }
            .padding(.horizontal, 13)
            .glassCard()

            Button(action: onResetColors) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise")
                    Text(L("set.resetColors"))
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                .overlay(Capsule().strokeBorder(Theme.edge))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, 4)
    }

    private func agentRow(_ agent: AgentSettingDescriptor) -> some View {
        HStack(spacing: 12) {
            BrandBadge(brand: agent.brand, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(L("set.agentPanelHint"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            agentToggle(agent: agent, title: L("set.agentPanel"), key: agent.showKey)
            agentToggle(agent: agent, title: L("set.agentMenubar"), key: agent.menubarKey)
            colorControl(agent)
        }
        .padding(.vertical, 11)
    }

    private func agentToggle(agent: AgentSettingDescriptor, title: String, key: String) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Theme.ink3)
            if GlassRender.useNativeEffect {
                Toggle("", isOn: bool(key))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(agent.brand.accent)
                    .accessibilityLabel(Text("\(agent.name) \(title)"))
            } else {
                previewToggle(isOn: values[key]?.boolVal ?? true, tint: agent.brand.accent)
                    .accessibilityLabel(Text("\(agent.name) \(title)"))
            }
        }
        .frame(width: 62)
    }

    private func previewToggle(isOn: Bool, tint: Color) -> some View {
        Capsule()
            .fill(isOn ? tint : Color.white.opacity(0.14))
            .frame(width: 34, height: 20)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(Color.white).frame(width: 16, height: 16).padding(2)
            }
    }

    private func colorControl(_ agent: AgentSettingDescriptor) -> some View {
        let custom = !(values[agent.colorKey]?.stringVal ?? "").isEmpty
        return VStack(spacing: 5) {
            Text(L("set.agentColor"))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Theme.ink3)
            HStack(spacing: 5) {
                AgentColorSwatch(
                    selection: colorBinding(agent),
                    accessibilityName: "\(agent.name) \(L("set.agentColor"))")
                Button {
                    onSet(agent.colorKey, .string(""))
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(!custom)
                .opacity(custom ? 1 : 0)
                .accessibilityHidden(!custom)
                .help(L("set.resetAgentColor", ["agent": agent.name]))
            }
        }
        .frame(width: 58)
    }

    private func bool(_ key: String) -> Binding<Bool> {
        Binding(get: { values[key]?.boolVal ?? true },
                set: { onSet(key, .bool($0)) })
    }

    private func colorBinding(_ agent: AgentSettingDescriptor) -> Binding<Color> {
        Binding(
            get: {
                Color(hexString: values[agent.colorKey]?.stringVal ?? "")
                    ?? Color(hexString: agent.defaultColor)
                    ?? agent.brand.accent
            },
            set: { onSet(agent.colorKey, .string($0.hexString)) })
    }
}

private struct AgentColorSwatch: View {
    let selection: Binding<Color>
    let accessibilityName: String

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selection.wrappedValue)
            .frame(width: 22, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.edgeHi))
            .overlay {
                if GlassRender.useNativeEffect {
                    ColorPicker("", selection: selection, supportsOpacity: false)
                        .labelsHidden()
                        .opacity(0.02)
                }
            }
            .frame(width: 22, height: 22)
            .clipped()
            .accessibilityLabel(Text(accessibilityName))
            .help(accessibilityName)
    }
}
