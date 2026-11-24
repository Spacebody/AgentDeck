import SwiftUI

enum DashboardStyle {
    static let background = Color(hex: 0x101315)
    static let accent = Color(hex: 0x9be4cd)
}

struct DashboardHeading: View {
    let text: String
    var count: Int? = nil
    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 13, weight: .semibold))
            if let count { Text("\(count)").foregroundStyle(Theme.ink3).monospacedDigit() }
            Spacer(minLength: 0)
        }.foregroundStyle(Theme.ink).font(.system(size: 12))
    }
}

struct SessionActivityLabel: View {
    let status: String
    let tool: String
    @ObservedObject private var palette = AgentColors.shared
    var body: some View {
        HStack(spacing: 5) {
            if status == "busy" {
                let color = Brand(rawValue: tool)?.accent ?? Theme.ok
                Circle().fill(color).frame(width: 6, height: 6)
                    .shadow(color: color.opacity(0.65), radius: 2)
                    .pulse().accessibilityHidden(true)
            }
            Text(L(status == "busy" ? "active.busy" : "active.idle"))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink2)
        }.fixedSize()
    }
}

struct DashboardActiveList: View {
    let sessions: [ActiveSession]
    var showsHeading = true
    var onOpen: (ActiveSession) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeading { DashboardHeading(text: L("active.running", ["n": "\(sessions.count)"])) }
            ForEach(Array(sessions.enumerated()), id: \.offset) { _, session in
                Button { onOpen(session) } label: {
                    HStack(spacing: 10) {
                        SessionIcon(tool: session.tool, badgeSize: 28)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(session.title ?? session.project ?? session.cwd ?? session.tool)
                                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(session.cwd ?? session.tool).font(.system(size: 10))
                                .foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 5) {
                            if let status = session.status, ["busy", "idle"].contains(status) {
                                SessionActivityLabel(status: status, tool: session.tool)
                            }
                            SessionSpeedView(request: session.performanceRequest)
                        }
                        if SessionTools.canFocus(session.tool) {
                            Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                        }
                    }.padding(.vertical, 9).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!SessionTools.canFocus(session.tool))
                    .help(SessionTools.canFocus(session.tool) ? L("v3.open") : "")
            }
        }
    }
}

struct DashboardDoneList: View {
    let events: [DoneEvent]
    var onOpen: (DoneEvent) -> Void
    @State private var expanded: Set<String> = []
    private var groups: [(String, [DoneEvent])] {
        Dictionary(grouping: events, by: { $0.cwd ?? $0.project ?? "" })
            .map { ($0.key, $0.value.sorted { $0.ts > $1.ts }) }
            .sorted { ($0.1.first?.ts ?? 0) > ($1.1.first?.ts ?? 0) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DashboardHeading(text: L("done.recent"))
            ForEach(groups, id: \.0) { path, items in
                VStack(alignment: .leading, spacing: 5) {
                    Button {
                        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "folder").foregroundStyle(Theme.ink3)
                            Text(items.first?.project ?? URL(fileURLWithPath: path).lastPathComponent)
                                .lineLimit(1).truncationMode(.middle)
                            Text("\(items.count)").foregroundStyle(Theme.ink3)
                            Spacer()
                            Image(systemName: expanded.contains(path) ? "chevron.down" : "chevron.right")
                        }.font(.system(size: 12, weight: .medium)).padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    ForEach(Array((expanded.contains(path) ? items : Array(items.prefix(1))).enumerated()), id: \.offset) { _, event in
                        Button { onOpen(event) } label: {
                            HStack(spacing: 8) {
                                SessionIcon(tool: event.tool)
                                Text(event.title ?? "").font(.system(size: 11)).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(Fmt.relative(Date(timeIntervalSince1970: event.ts)))
                                    .font(.system(size: 10)).foregroundStyle(Theme.ink3)
                            }.padding(.vertical, 7).padding(.leading, 22).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!SessionTools.canFocus(event.tool))
                    }
                }
                Divider().opacity(0.4)
            }
        }
    }
}

struct QuotaAmountRows: View {
    let amounts: [QuotaAmount]
    var body: some View {
        ForEach(amounts) { item in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.label ?? item.id)
                    Spacer(minLength: 4)
                    Text(L("quota.amountRemaining", ["n": item.remaining.formatted()])).monospacedDigit()
                }
                if let date = item.resetsAt?.date {
                    Text(Fmt.countdown(date)).foregroundStyle(Theme.ink3)
                }
            }.font(.system(size: 11))
        }
    }
}

struct DashboardQuota: View {
    @ObservedObject private var palette = AgentColors.shared
    let brand: Brand
    let node: QuotaNode
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 10) {
            HStack(spacing: 6) {
                BrandGlyph(brand: brand, glyph: compact ? 14 : MiniDonut.defaultDiameter)
                Text(brand.rawValue == "qoder_cn" ? "Qoder CN" : brand.rawValue.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            if let account = node.account, !account.isEmpty {
                Text(account).font(.system(size: 10)).foregroundStyle(Theme.ink3)
                    .lineLimit(1).truncationMode(.middle).help(account)
            }
            ForEach(node.displayWindows) { window in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(window.displayLabel).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text("\(Int(window.usedPercent.rounded()))%")
                            .font(.system(size: 14, weight: .semibold)).monospacedDigit().fixedSize()
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(window.usedPercent >= 95 ? Theme.danger : window.usedPercent >= 80 ? Theme.warn :
                                brand.accent)
                                .frame(width: proxy.size.width * min(100, max(0, window.usedPercent)) / 100)
                        }
                    }.frame(height: 5)
                    if !compact, let date = window.resetsAt?.date {
                        Text(Fmt.countdown(date)).font(.system(size: 10)).foregroundStyle(Theme.ink3)
                    }
                }
            }
            QuotaAmountRows(amounts: node.remainingAmounts ?? [])
            if node.displayWindows.isEmpty && (node.remainingAmounts ?? []).isEmpty {
                Text(L(node.hidden == true ? "quota.loading" : node.noQuota == true ? (brand == .antigravity ? "quota.noAntigravitySample" : "quota.noQuota") : node.ok == true ? "quota.noOther" : "quota.fetchFailed"))
                    .font(.system(size: 11)).foregroundStyle(Theme.ink3)
                if node.hidden != true, !(brand == .antigravity && node.noQuota == true), let error = node.error, !error.isEmpty {
                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.warn)
                        .lineLimit(3).help(error)
                }
            }
            if let status = quotaStatusInfo(node: node) {
                Text(status.text).font(.system(size: compact ? 10 : 11)).foregroundStyle(status.stale ? Theme.warn : Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
