// AgentDeck v2 — 设置页。按 SettingsSchema 泛型渲染六种行型，分区成卡。
// 值经 values 字典读、onSet 写（接 store 时 POST /api/settings）；动作经 onAction。
import SwiftUI

struct SettingsView: View {
    var values: [String: SettingValue] = [:]
    var scrollable: Bool = true
    /// 已安装终端（mode, name）；用于「恢复方式」动态选项（对应 v1 /api/terminals）。
    var terminals: [(String, String)] = []
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
            // 标题由外壳 .sethead 提供（设置浮层顶部），此处直接从首个分区开始。
            ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                Text(L(g.title).uppercased())
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
            Text("AgentDeck v\(version) · \(L("set.dataLocal"))")
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
            // 成排 chip 走整行块式（标签在上、chip 右对齐自动换行在下），避免被标签挤成「1 分 钟」竖排。
            setrowBlock(label, hint) { chips(key: key, opts: opts, fmt: fmt, custom: custom) }
        case let .select(key, label, hint, opts):
            // 恢复方式：auto + 已安装终端 + copy（对应 v1 /api/terminals 动态注入）。
            let effective = key == "terminal" && !terminals.isEmpty
                ? [("auto", "set.termAuto")] + terminals + [("copy", "set.termCopy")]
                : opts
            setrow(label, hint) { selectMenu(key: key, opts: effective) }
        case let .multi(label, hint, opts):
            setrow(label, hint) {
                HStack(spacing: 4) {
                    ForEach(opts, id: \.0) { k, name in
                        Chip(text: L(name), on: values[k]?.boolVal ?? false, size: 11.5) { onSet(k, .bool(!(values[k]?.boolVal ?? false))) }
                    }
                }
            }
        case let .colors(label, hint, opts):
            setrow(label, hint) {
                HStack(spacing: 8) {
                    ForEach(opts, id: \.0) { k, _, def in colorSwatch(k, def: def) }
                    Button(L("set.resetColors"), action: onResetColors)
                        .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                        .fixedSize()
                }
            }
        case let .btns(label, hint, btns):
            setrow(label, hint) {
                HStack(spacing: 6) {
                    ForEach(btns, id: \.0) { act, name in
                        Button(L(name)) { onAction(act) }
                            .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold))
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
                Text(L(label)).font(.system(size: 13)).foregroundStyle(Theme.ink)
                if let hint { Text(L(hint)).font(.system(size: 10.5)).foregroundStyle(Theme.ink3) }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 10)
    }

    /// 块式行：标签/说明在上，控件整行在下右对齐（成排 chip 用，给足横向空间自动换行）。
    private func setrowBlock<C: View>(_ label: String, _ hint: String?, @ViewBuilder control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L(label)).font(.system(size: 13)).foregroundStyle(Theme.ink)
                if let hint { Text(L(hint)).font(.system(size: 10.5)).foregroundStyle(Theme.ink3) }
            }
            control().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    // MARK: chips（含自定义编辑）。FlowLayout 自动换行 + 右对齐（对应 v1 .setchips flex-wrap）。
    @ViewBuilder private func chips(key: String, opts: [Int], fmt: ChipFmt, custom: ClosedRange<Int>?) -> some View {
        let cur = values[key]?.intVal ?? opts.first ?? 0
        let isCustom = !opts.contains(cur)
        FlowLayout(spacing: 4, lineSpacing: 6) {
            ForEach(opts, id: \.self) { o in
                Chip(text: fmt.text(o), on: cur == o && !editing(key), size: 11.5) { onSet(key, .int(o)); editingKey = nil }
            }
            if isCustom && !editing(key) {
                Chip(text: fmt.text(cur), on: true, size: 11.5) { startEdit(key, cur) }
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
                    Chip(text: L("set.custom"), on: false, size: 11.5) { startEdit(key, cur) }
                }
            }
        }
    }

    private func selectMenu(key: String, opts: [(String, String)]) -> some View {
        let cur = values[key]?.stringVal ?? opts.first?.0 ?? ""
        return Menu {
            ForEach(opts, id: \.0) { v, name in Button(L(name)) { onSet(key, .string(v)) } }
        } label: {
            HStack(spacing: 5) {
                Text(L(opts.first { $0.0 == cur }?.1 ?? cur)).font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.edge))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: 绑定/编辑辅助
    private func bool(_ key: String) -> Binding<Bool> {
        Binding(get: { values[key]?.boolVal ?? false }, set: { onSet(key, .bool($0)) })
    }
    /// 22×22 圆角色块（对应 v1 .colordot 22px swatch）。系统 ColorPicker 色井在 macOS 上
    /// 尺寸固定且偏大，硬塞 frame 会溢出挤掉「恢复默认」；改为自绘色块 + 顶一层近透明 ColorPicker
    /// 接管点击（裁到 22×22），既受控又能弹系统取色盘。
    private func colorSwatch(_ key: String, def: String) -> some View {
        let binding = colorBinding(key, def: def)
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(binding.wrappedValue)
            .frame(width: 22, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.edgeHi))
            .overlay(
                SwiftUI.Group {
                    if GlassRender.useNativeEffect {   // 无头预览不放 NSView 色井（会出禁止符占位）
                        ColorPicker("", selection: binding, supportsOpacity: false)
                            .labelsHidden()
                            .opacity(0.02)            // 隐形但可点
                    }
                }
            )
            .frame(width: 22, height: 22)
            .clipped()                        // 裁掉溢出的系统色井，布局只占 22pt
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
