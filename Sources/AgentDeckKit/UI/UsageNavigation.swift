import SwiftUI

struct OriginViewportKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

extension AnalyticsQuery {
    var isSingleCalendarDay: Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        return calendar.isDate(Date(timeIntervalSince1970: Double(start)),
                               inSameDayAs: Date(timeIntervalSince1970: Double(end - 1)))
    }
}

struct UsageDestination: Hashable {
    let scope: AnalyticsScope
    let title: String
    let agents: Set<String>

    func visibleAgents(in enabled: Set<String>) -> Set<String> {
        if case let .session(agent, _, _, _) = scope { return enabled.intersection([agent]) }
        return enabled
    }

    var scopeLabel: String {
        switch scope {
        case .all: return L("tab.usage")
        case .session: return L("tab.sessions")
        case .project: return L("analytics.project")
        }
    }
}

struct UsageNavigation {
    private(set) var tab: String
    private(set) var destination: UsageDestination?
    var selectedTab: String { destination == nil ? tab : "usage" }

    init(tab: String = "overview") { self.tab = tab }
    mutating func select(_ tab: String) { destination = nil; self.tab = tab }
    mutating func open(_ destination: UsageDestination) { self.destination = destination }
    mutating func back() { destination = nil }
}

private struct OpenAnalyticsKey: EnvironmentKey {
    static let defaultValue: (UsageDestination, AnalyticsSnapshot?) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var openAnalytics: (UsageDestination, AnalyticsSnapshot?) -> Void {
        get { self[OpenAnalyticsKey.self] }
        set { self[OpenAnalyticsKey.self] = newValue }
    }
}
