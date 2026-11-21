import Foundation

package struct IslandEvent: Equatable {
    package let tool: String
    package let title: String
    package let project: String
    package let session: String
    package let cwd: String
    package let kind: String
    package let level: String
    package let dedupeKey: String
    package let timestamp: TimeInterval

    package static func isFresh(_ timestamp: TimeInterval, now: TimeInterval) -> Bool {
        (0...60).contains(now - timestamp)
    }

    package init(
        tool: String, title: String, project: String, session: String, cwd: String,
        kind: String, level: String, dedupeKey: String,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.tool = tool
        self.title = title
        self.project = project
        self.session = session
        self.cwd = cwd
        self.kind = kind
        self.level = level
        self.dedupeKey = dedupeKey
        self.timestamp = timestamp
    }
}

package struct IslandEventQueue {
    private var events: [IslandEvent] = []

    package init() {}

    package var isEmpty: Bool { events.isEmpty }
    package var count: Int { events.count }

    package mutating func enqueue(_ event: IslandEvent) {
        if event.kind == "alert", !event.dedupeKey.isEmpty,
           let index = events.firstIndex(where: {
               $0.kind == "alert" && $0.dedupeKey == event.dedupeKey
           }) {
            events[index] = event
        } else if event.kind != "alert",
                  let firstAlert = events.firstIndex(where: { $0.kind == "alert" }) {
            events.insert(event, at: firstAlert)
        } else {
            events.append(event)
        }
    }

    package mutating func popFirst(now: TimeInterval = Date().timeIntervalSince1970) -> IslandEvent? {
        events.removeAll { !IslandEvent.isFresh($0.timestamp, now: now) }
        guard !events.isEmpty else { return nil }
        return events.removeFirst()
    }
}

package enum IslandQueueTiming {
    package static func deadline(
        shownAt: Date, configuredDwell: TimeInterval, hasPending: Bool
    ) -> Date {
        let dwell = hasPending ? min(configuredDwell, 2) : configuredDwell
        return shownAt.addingTimeInterval(dwell)
    }
}
