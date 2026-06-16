// AgentDeck v2 — 设置页。按 SettingsSchema 泛型渲染六种行型，分区成卡。
// 值经 values 字典读、onSet 写（接 store 时 POST /api/settings）；动作经 onAction。
import SwiftUI

struct SettingsView: View {
    var values: [String: SettingValue] = [:]
    var scrollable: Bool = true
    var onSet: (String, SettingValue) -> Void = { _, _ in }
    var onAction: (String) -> Void = { _ in }
    var onResetColors: () -> Void = {}
    var version: String = "dev"

    @State private var editingKey: String?
    @State private var editText: String = ""

    // 把 schema 按 section 切成卡
    private struct Group { let title: String; let rows: [SetRow] }
    private var groups: [Group] {
        var out: [Group] = []; var title = ""; var cur: [SetRow] = []
        func flush() { if !title.isEmpty { out.append(Group(title: title, rows: cur)) }; cur = [] }
        for r in SettingsSchema.rows {
            if case .section(let s) = r { flush(); title = s } else { cur.append(r) }
        }
        flush(); return out
    }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            HStack { Text("设置").font(.rounded(17, weight: .heavy)); Spacer() }
                .padding(.bottom, 6)
            ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                Text(g.title.uppercased())
                    .font(.system(size: 12, weight: .heavy)).foregroundStyle(Theme.ink2)
                    .tracking(1.2).padding(.top, 14).padding(.bottom, 7).padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(Array(g.rows.enumerated()), id: \.offset) { idx, row in
                        rowView(row)
                        if idx < g.rows.count - 1 { Divider().overlay(Color.white.opacity(0.06)) }
                    }
                }
                .padding(.horizontal, 13)
                .glassCard()
            }
            Text("AgentDeck v\(version)")
                .font(.rounded(9)).foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity).padding(.top, 10)
        }
        if scrollable { ScrollView { content }.scrollIndicators(.hidden) } else { content }
    }

    // MARK: 单行
    @ViewBuilder private func rowView(_ row: SetRow) -> some View {
        switch row {
        case .section: EmptyView()
        case let .toggle(key, label, hint):
            setrow(label, hint) {
                Toggle("", isOn: bool(key)).labelsHidden().toggleStyle(.switch).tint(Brand.claude.accent)
            }
        case let .chips(key, label, hint, opts, fmt, custom):
            setrow(label, hint) { chips(key: key, opts: opts, fmt: fmt, custom: custom) }
        case let .select(key, label, hint, opts):
            setrow(label, hint) { selectMenu(key: key, opts: opts) }
        case let .multi(label, hint, opts):
            setrow(label, hint) {
                HStack(spacing: 4) {
                    ForEach(opts, id: \.0) { k, name in
                        Chip(text: name, on: values[k]?.boolVal ?? false) { onSet(k, .bool(!(values[k]?.boolVal ?? false))) }
                    }
                }
            }
        case let .colors(label, hint, opts):
            setrow(label, hint) {
                HStack(spacing: 8) {
                    ForEach(opts, id: \.0) { k, name, def in
                        ColorPicker(selection: colorBinding(k, def: def), supportsOpacity: false) {
                            Text(name).font(.system(size: 11)).foregroundStyle(Theme.ink2)
                        }
                        .labelsHidden().frame(width: 22, height: 22)
                    }
                    Button("恢复默认", action: onResetColors)
                        .buttonStyle(.plain).font(.system(size: 9.5)).foregroundStyle(Theme.ink3)
                }
            }
        case let .btns(label, hint, btns):
            setrow(label, hint) {
                HStack(spacing: 6) {
                    ForEach(btns, id: \.0) { act, name in
                        Button(name) { onAction(act) }
                            .buttonStyle(.plain).font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .overlay(Capsule().strokeBorder(Theme.edge))
                    }
                }
            }
        }
    }

    private func setrow<C: View>(_ label: String, _ hint: String?, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 13)).foregroundStyle(Theme.ink)
                if let hint { Text(hint).font(.system(size: 10.5)).foregroundStyle(Theme.ink3) }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 10)
    }

    // MARK: chips（含自定义编辑）
    @ViewBuilder private func chips(key: String, opts: [Int], fmt: ChipFmt, custom: ClosedRange<Int>?) -> some View {
        let cur = values[key]?.intVal ?? opts.first ?? 0
        let isCustom = !opts.contains(cur)
        HStack(spacing: 4) {
            ForEach(opts, id: \.self) { o in
                Chip(text: fmt.text(o), on: cur == o && !editing(key)) { onSet(key, .int(o)); editingKey = nil }
            }
            if isCustom && !editing(key) {
                Chip(text: fmt.text(cur), on: true) { startEdit(key, cur) }
            }
            if custom != nil {
                if editing(key) {
                    TextField("", text: $editText)
                        .textFieldStyle(.plain).frame(width: 44).font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                        .onSubmit { commitEdit(key, custom!) }
                } else {
                    Chip(text: "自定义", on: false) { startEdit(key, cur) }
                }
            }
        }
    }

    private func selectMenu(key: String, opts: [(String, String)]) -> some View {
        let cur = values[key]?.stringVal ?? opts.first?.0 ?? ""
        return Menu {
            ForEach(opts, id: \.0) { v, name in Button(name) { onSet(key, .string(v)) } }
        } label: {
            HStack(spacing: 5) {
                Text(opts.first { $0.0 == cur }?.1 ?? cur).font(.system(size: 10.5, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.edge))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: 绑定/编辑辅助
    private func bool(_ key: String) -> Binding<Bool> {
        Binding(get: { values[key]?.boolVal ?? false }, set: { onSet(key, .bool($0)) })
    }
    private func colorBinding(_ key: String, def: String) -> Binding<Color> {
        Binding(get: { Color(hexString: values[key]?.stringVal ?? def) ?? Color(hexString: def)! },
                set: { onSet(key, .string($0.hexString)) })
    }
    private func editing(_ key: String) -> Bool { editingKey == key }
    private func startEdit(_ key: String, _ cur: Int) { editingKey = key; editText = String(cur) }
    private func commitEdit(_ key: String, _ range: ClosedRange<Int>) {
        if let v = Int(editText) { onSet(key, .int(min(max(v, range.lowerBound), range.upperBound))) }
        editingKey = nil
    }
}

// MARK: - Color ↔ hex 串
extension Color {
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let v = UInt32(s, radix: 16), s.count == 6 else { return nil }
        self.init(hex: v)
    }
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02x%02x%02x",
                      Int(round(ns.redComponent * 255)),
                      Int(round(ns.greenComponent * 255)),
                      Int(round(ns.blueComponent * 255)))
    }
}
