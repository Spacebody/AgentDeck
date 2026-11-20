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
    let defaultShow: Bool
    let defaultMenubar: Bool
}

enum AgentSettingsCatalog {
    static let all: [AgentSettingDescriptor] = [
        .init(id: "claude", name: "Claude", brand: .claude,
              showKey: "show_claude", menubarKey: "menubar_claude",
              colorKey: "color_claude", defaultColor: "#ff9d7a",
              defaultShow: true, defaultMenubar: true),
        .init(id: "codex", name: "Codex", brand: .codex,
              showKey: "show_codex", menubarKey: "menubar_codex",
              colorKey: "color_codex", defaultColor: "#8be9e2",
              defaultShow: true, defaultMenubar: true),
        .init(id: "qoder", name: "Qoder", brand: .qoder,
              showKey: "show_qoder", menubarKey: "menubar_qoder",
              colorKey: "color_qoder", defaultColor: "#a78bfa",
              defaultShow: true, defaultMenubar: true),
        .init(id: "qoder_cn", name: "Qoder CN", brand: .qoderCn,
              showKey: "show_qoder_cn", menubarKey: "menubar_qoder_cn",
              colorKey: "color_qoder_cn", defaultColor: "#818cf8",
              defaultShow: false, defaultMenubar: false),
    ]

    static let visibilityKeys = Set(all.map(\.showKey))
    static let menubarKeys = Set(all.map(\.menubarKey))
    static let colorKeys = Set(all.map(\.colorKey))

    static func enabledCount(in values: [String: SettingValue]) -> Int {
        all.reduce(0) {
            $0 + ((values[$1.showKey]?.boolVal ?? $1.defaultShow) ? 1 : 0)
        }
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
    @State private var editingColor: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("set.agentManagerHint"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(AgentSettingsCatalog.all.enumerated()), id: \.element.id) { index, agent in
                    agentRow(agent)
                    if editingColor == agent.id {
                        AgentPalette(initial: colorBinding(agent).wrappedValue.hexString,
                                     apply: { onSet(agent.colorKey, .string($0)); editingColor = nil },
                                     cancel: { editingColor = nil })
                            .id(agent.id)
                    }
                    if index < AgentSettingsCatalog.all.count - 1 {
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
            }
            .padding(.horizontal, 13)
            Divider()

            Button { editingColor = nil; onResetColors() } label: {
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
        let identity = HStack(spacing: 10) {
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

        }
        let controls = HStack(spacing: 8) {
            agentToggle(agent: agent, title: L("set.agentPanel"), key: agent.showKey)
            agentToggle(agent: agent, title: L("set.agentMenubar"), key: agent.menubarKey)
            colorControl(agent)
        }
        return ViewThatFits(in: .horizontal) {
            HStack { identity.frame(minWidth: 105); controls }
            VStack(alignment: .leading, spacing: 10) { identity; controls }
        }.padding(.vertical, 11)
    }

    private func agentToggle(agent: AgentSettingDescriptor, title: String, key: String) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Theme.ink3)
            if GlassRender.useNativeEffect {
                Toggle("", isOn: bool(key, fallback: key == agent.showKey
                                       ? agent.defaultShow : agent.defaultMenubar))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(agent.brand.accent)
                    .accessibilityLabel(Text("\(agent.name) \(title)"))
            } else {
                previewToggle(isOn: values[key]?.boolVal ?? (key == agent.showKey
                                  ? agent.defaultShow : agent.defaultMenubar),
                              tint: agent.brand.accent)
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
                Button {
                    editingColor = editingColor == agent.id ? nil : agent.id
                } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(colorBinding(agent).wrappedValue)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.edgeHi))
                        .frame(width: 20, height: 20)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(agent.name) \(L("set.agentColor"))")
                .accessibilityIdentifier("agent-color-\(agent.id)")
                Button {
                    editingColor = nil
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

    private func bool(_ key: String, fallback: Bool) -> Binding<Bool> {
        Binding(get: { values[key]?.boolVal ?? fallback },
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

struct AgentPalette: View {
    let apply: (String) -> Void
    let cancel: () -> Void
    @State private var draft: String
    @State private var rgb: Int

    init(initial: String, apply: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.apply = apply
        self.cancel = cancel
        _draft = State(initialValue: initial)
        _rgb = State(initialValue: Self.parse(initial) ?? 0)
    }

    static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? trimmed.dropFirst() : trimmed[...]
        guard digits.utf8.count == 6, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return Int(digits, radix: 16)
    }

    static func hex(_ rgb: Int) -> String { String(format: "#%06x", rgb) }

    private func choose(_ value: Int) {
        rgb = value
        draft = Self.hex(value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach([0xff9d7a, 0x8be9e2, 0xa78bfa, 0x818cf8, 0x79ce98, 0xffca68], id: \.self) { value in
                    Button { choose(value) } label: {
                        RoundedRectangle(cornerRadius: 4).fill(Color(hex: UInt32(value)))
                            .frame(width: 20, height: 20)
                            .overlay {
                                if rgb == value { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.black) }
                            }
                    }.buttonStyle(.plain).accessibilityLabel(Self.hex(value))
                }
            }
            channelRow("R", shift: 16)
            channelRow("G", shift: 8)
            channelRow("B", shift: 0)
            HStack {
                RoundedRectangle(cornerRadius: 4).fill(Color(hex: UInt32(rgb))).frame(width: 20, height: 20)
                TextField("#RRGGBB", text: Binding(get: { draft }, set: {
                    draft = $0
                    if let value = Self.parse($0) { rgb = value }
                })).frame(width: 80).onSubmit { commit() }
                Spacer(minLength: 2)
                Button(action: cancel) {
                    Image(systemName: "xmark").frame(width: 26, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Theme.ink2).accessibilityLabel(L("session.cancel"))
                Button(action: commit) {
                    Image(systemName: "checkmark").frame(width: 26, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(DashboardStyle.accent)
                    .disabled(Self.parse(draft) == nil).accessibilityLabel(L("set.applyColor"))
                    .help(L("set.applyColor"))
            }
        }.font(.system(size: 12)).controlSize(.small).tint(DashboardStyle.accent)
            .padding(.vertical, 8).onExitCommand(perform: cancel)
    }

    private func commit() {
        if let value = Self.parse(draft) { apply(Self.hex(value)) }
    }

    private func channelRow(_ label: String, shift: Int) -> some View {
        HStack {
            Text(label).frame(width: 14)
            ChannelControl(label: label, value: (rgb >> shift) & 255) { channel in
                choose((rgb & ~(255 << shift)) | (channel << shift))
            }.frame(height: 22)
        }
    }
}

private struct ChannelControl: NSViewRepresentable {
    let label: String
    let value: Int
    let changed: (Int) -> Void

    final class Control: NSStackView {
        let slider = NSSlider(value: 0, minValue: 0, maxValue: 255, target: nil, action: nil)
        let number = NSTextField(labelWithString: "0")
        var changed: ((Int) -> Void)?
        override init(frame: NSRect) {
            super.init(frame: frame)
            orientation = .horizontal
            spacing = 8
            number.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            number.alignment = .right
            number.widthAnchor.constraint(equalToConstant: 30).isActive = true
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(moved)
            slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
            addArrangedSubview(slider)
            addArrangedSubview(number)
        }
        required init?(coder: NSCoder) { nil }
        @objc func moved() {
            let value = Int(slider.doubleValue.rounded())
            number.stringValue = String(value)
            changed?(value)
        }
    }

    func makeNSView(context: Context) -> Control { Control(frame: .zero) }
    func updateNSView(_ view: Control, context: Context) {
        view.changed = changed
        view.slider.setAccessibilityLabel(label)
        if Int(view.slider.doubleValue.rounded()) != value { view.slider.doubleValue = Double(value) }
        view.number.stringValue = String(value)
    }
}
